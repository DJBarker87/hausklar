import Foundation

enum FitnessNutritionMeasurementQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case weighed, measured
    case standardServing = "standard_serving"
    case estimated
    case restaurantEstimate = "restaurant_estimate"

    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
    var isEstimate: Bool { self == .estimated || self == .restaurantEstimate }
}

enum FitnessNutritionTargetMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case fixed, range
    case weeklyAverage = "weekly_average"
    case trainingRest = "training_rest"
    case phase

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fixed: "Fixed daily"
        case .range: "Daily range"
        case .weeklyAverage: "Weekly average"
        case .trainingRest: "Training vs rest"
        case .phase: "Training phase"
        }
    }
}

enum FitnessNutritionMetric: String, Codable, CaseIterable, Identifiable, Sendable {
    case caloriesKcal = "calories_kcal"
    case proteinG = "protein_g"
    case carbohydrateG = "carbohydrate_g"
    case fibreG = "fibre_g"
    case fatG = "fat_g"
    case saturatedFatG = "saturated_fat_g"
    case sugarsG = "sugars_g"
    case saltG = "salt_g"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .caloriesKcal: "Calories"
        case .proteinG: "Protein"
        case .carbohydrateG: "Carbohydrate"
        case .fibreG: "Fibre"
        case .fatG: "Fat"
        case .saturatedFatG: "Saturated fat"
        case .sugarsG: "Sugars"
        case .saltG: "Salt"
        }
    }
    var unit: String { self == .caloriesKcal ? "kcal" : "g" }
}

struct FitnessNutritionValues: Codable, Equatable, Sendable {
    var caloriesKcal: Double?
    var proteinG: Double?
    var carbohydrateG: Double?
    var sugarsG: Double?
    var fatG: Double?
    var saturatedFatG: Double?
    var fibreG: Double?
    var saltG: Double?
    var sodiumMg: Double? = nil
    var micronutrients: [String: Double?] = [:]

    static let unknown = FitnessNutritionValues(
        caloriesKcal: nil, proteinG: nil, carbohydrateG: nil, sugarsG: nil,
        fatG: nil, saturatedFatG: nil, fibreG: nil, saltG: nil
    )

    func scaled(by factor: Double) -> Self {
        func scale(_ value: Double?) -> Double? { value.map { $0 * factor } }
        return Self(
            caloriesKcal: scale(caloriesKcal), proteinG: scale(proteinG),
            carbohydrateG: scale(carbohydrateG), sugarsG: scale(sugarsG),
            fatG: scale(fatG), saturatedFatG: scale(saturatedFatG),
            fibreG: scale(fibreG), saltG: scale(saltG), sodiumMg: scale(sodiumMg),
            micronutrients: micronutrients.mapValues { scale($0) }
        )
    }

    static func exactTotal(_ values: [Self]) -> Self {
        func total(_ field: (Self) -> Double?) -> Double? {
            let samples = values.map(field)
            guard !samples.isEmpty, !samples.contains(where: { $0 == nil }) else { return nil }
            return samples.compactMap { $0 }.reduce(0, +)
        }
        return Self(
            caloriesKcal: total(\.caloriesKcal), proteinG: total(\.proteinG),
            carbohydrateG: total(\.carbohydrateG), sugarsG: total(\.sugarsG),
            fatG: total(\.fatG), saturatedFatG: total(\.saturatedFatG),
            fibreG: total(\.fibreG), saltG: total(\.saltG), sodiumMg: total(\.sodiumMg)
        )
    }
}

struct FitnessFoodVersion: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var foodId: String
    var versionNumber: Int?
    var effectiveFrom: String?
    var referenceAmount: Double
    var referenceUnit: String
    var caloriesKcal: Double?
    var sourceEnergyValue: Double?
    var sourceEnergyUnit: String?
    var proteinG: Double?
    var carbohydrateG: Double?
    var sugarsG: Double?
    var fatG: Double?
    var saturatedFatG: Double?
    var fibreG: Double?
    var saltG: Double?
    var sodiumMg: Double?
    var micronutrients: [String: Double?]
    var sourceType: String
    var sourceNote: String?
    var confidence: String
    var labelAssetId: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    var nutrients: FitnessNutritionValues {
        FitnessNutritionValues(
            caloriesKcal: authoritativeCalories, proteinG: proteinG,
            carbohydrateG: carbohydrateG, sugarsG: sugarsG, fatG: fatG,
            saturatedFatG: saturatedFatG, fibreG: fibreG, saltG: saltG,
            sodiumMg: sodiumMg, micronutrients: micronutrients
        )
    }

    var authoritativeCalories: Double? {
        // Persisted kcal is the analytical truth. Original kJ/kcal remains
        // provenance and is never re-converted while reading history.
        caloriesKcal
    }
}

struct FitnessFoodServing: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var foodId: String
    var name: String
    var amount: Double
    var unit: String
    var canonicalAmount: Double
    var canonicalUnit: String
    var measurementQuality: FitnessNutritionMeasurementQuality
    var isDefault: Bool
    var active: Bool
    var revision: Int
    var updatedAt: Date
    var deletedAt: Date?
}

struct FitnessFoodQuickUse: Codable, Equatable, Sendable {
    var lastLoggedAtUtc: Date?
    var lastAmount: Double?
    var lastUnit: String?
    var usualAmount: Double?
    var usualUnit: String?
    var frequencyCount: Int
    var recentMealKeys: [FitnessMeal]
}

struct FitnessRecipeComponent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var foodVersionId: String
    var foodName: String?
    var amount: Double
    var unit: String
    var canonicalAmount: Double
    var canonicalUnit: String
    var sequence: Int
}

struct FitnessRecipeVersion: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var recipeId: String
    var versionNumber: Int?
    var components: [FitnessRecipeComponent]
    var finishedWeightG: Double?
    var servings: Double?
    var nutrients: FitnessNutritionValues
    var per100G: FitnessNutritionValues?
    var lowerCaloriesKcal: Double?
    var upperCaloriesKcal: Double?
    var confidence: String
    var sourceNote: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

struct FitnessRecipe: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var notes: String?
    var householdShared: Bool
    var favourite: Bool
    var active: Bool
    var editable: Bool = true
    var versions: [FitnessRecipeVersion]
    var revision: Int
    var updatedAt: Date
    var deletedAt: Date?

    var currentVersion: FitnessRecipeVersion? {
        versions.max { ($0.versionNumber ?? 0) < ($1.versionNumber ?? 0) }
    }
}

/// Centralises the owner/private action contract so list and detail surfaces
/// cannot accidentally expose mutations for another household member's data.
struct FitnessNutritionActionAvailability: Equatable, Sendable {
    let canLog: Bool
    let canCopy: Bool
    let canEditIdentity: Bool
    let canAddVersion: Bool
    let canFavourite: Bool
    let canArchive: Bool
    let canMerge: Bool

    static func food(_ food: FitnessFood) -> Self {
        Self(
            canLog: food.active && food.currentVersion != nil,
            canCopy: !food.editable && food.currentVersion != nil,
            canEditIdentity: food.editable,
            canAddVersion: food.editable,
            canFavourite: food.editable,
            canArchive: food.editable,
            canMerge: food.editable
        )
    }

    static func recipe(_ recipe: FitnessRecipe) -> Self {
        Self(
            canLog: recipe.active && recipe.currentVersion != nil,
            canCopy: !recipe.editable && recipe.currentVersion != nil,
            canEditIdentity: recipe.editable,
            canAddVersion: recipe.editable,
            canFavourite: recipe.editable,
            canArchive: recipe.editable,
            canMerge: false
        )
    }
}

struct FitnessMealTemplateItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var foodVersionId: String?
    var recipeVersionId: String?
    var label: String?
    var amount: Double
    var unit: String
    var canonicalAmount: Double
    var canonicalUnit: String
    var measurementQuality: FitnessNutritionMeasurementQuality
    var sequence: Int

    var hasExactlyOneSource: Bool { (foodVersionId == nil) != (recipeVersionId == nil) }
}

struct FitnessMealTemplate: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var meal: FitnessMeal
    var timeRelevance: String?
    var favourite: Bool
    var active: Bool
    var items: [FitnessMealTemplateItem]
    var revision: Int
    var updatedAt: Date
    var deletedAt: Date?
}

struct FitnessNutritionTarget: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var metric: FitnessNutritionMetric
    var mode: FitnessNutritionTargetMode
    var targetValue: Double?
    var targetMin: Double?
    var targetMax: Double?
    var trainingDayValue: Double?
    var restDayValue: Double?
    var phaseId: String?
    var effectiveFrom: String
    var effectiveUntil: String?
    var active: Bool
    var revision: Int
    var updatedAt: Date
    var deletedAt: Date?

    var isValid: Bool {
        func nonnegative(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } == true }
        switch mode {
        case .fixed, .weeklyAverage: return nonnegative(targetValue)
        case .range:
            guard let targetMin, let targetMax else { return false }
            return nonnegative(targetMin) && nonnegative(targetMax) && targetMax >= targetMin
        case .trainingRest: return nonnegative(trainingDayValue) && nonnegative(restDayValue)
        case .phase: return phaseId != nil && nonnegative(targetValue)
        }
    }
}

struct FitnessNutritionSettings: Codable, Equatable, Sendable {
    var id: String
    var timezone: String
    var nutritionDayStartMinutes: Int
    var heartRateZoneBoundariesBpm: [Int]? = nil
    var revision: Int
}

struct FitnessNutritionDay: Equatable, Sendable {
    var nutritionDate: String
    var entries: [FitnessFoodLogEntry]
    var totals: FitnessNutritionValues
    var uncertainMetrics: Set<FitnessNutritionMetric>
    var measuredShare: Double?
    var estimatedShare: Double?
}

struct FitnessNutritionAnalysis: Codable, Equatable, Sendable {
    var start: String
    var end: String
    var sampleDays: Int
    var calendarDays: Int
    var completeness: Double
    var contributors: [FitnessNutritionAnalysisContributor]
    var recommendation: FitnessNutritionRecommendation?
}

struct FitnessNutritionAnalysisContributor: Codable, Identifiable, Equatable, Sendable {
    var itemId: String
    var itemKind: String
    var label: String
    var mealKey: String
    var nutrientKey: String
    var total: Double
    var share: Double?
    var entryCount: Int
    var sampleDays: Int
    var typicalAmount: Double?
    var typicalUnit: String?

    var id: String { "\(nutrientKey):\(itemKind):\(itemId):\(mealKey)" }
}

struct FitnessNutritionRecommendation: Codable, Equatable, Sendable {
    var foodOrMeal: String
    var itemId: String
    var itemKind: String
    var mealKey: String
    var observationPeriod: FitnessNutritionObservationPeriod
    var calculation: FitnessNutritionRecommendationCalculation
    var frequency: FitnessNutritionRecommendationFrequency
    var typicalAmount: FitnessNutritionRecommendationAmount
    var proposedChange: FitnessNutritionProposedChange
    var expectedEffect: FitnessNutritionExpectedEffect
    var uncertainty: FitnessNutritionRecommendationUncertainty
    var whyPractical: String
}

struct FitnessNutritionRecommendationCalculation: Codable, Equatable, Sendable {
    var observedAverageCaloriesKcal: Double
    var targetAverageCaloriesKcal: Double
    var averageGapCaloriesKcal: Double
    var minimumMaterialGapCaloriesKcal: Double
    var targetDays: Int
}

struct FitnessNutritionObservationPeriod: Codable, Equatable, Sendable {
    var start: String
    var end: String
    var calendarDays: Int
    var loggedDays: Int
}

struct FitnessNutritionRecommendationFrequency: Codable, Equatable, Sendable {
    var entries: Int
    var days: Int
    var perWeek: Double
}

struct FitnessNutritionRecommendationAmount: Codable, Equatable, Sendable {
    var value: Double
    var unit: String
}

struct FitnessNutritionProposedChange: Codable, Equatable, Sendable {
    var kind: String
    var fraction: Double
    var amount: Double
    var unit: String
    var resultingAmount: Double
    var description: String
}

struct FitnessNutritionExpectedEffect: Codable, Equatable, Sendable {
    var perOccurrenceCaloriesKcal: Double
    var periodCaloriesKcal: Double
    var weeklyCaloriesKcal: Double
}

struct FitnessNutritionRecommendationUncertainty: Codable, Equatable, Sendable {
    var nutrientCompleteness: Double
    var diaryDayCompleteness: Double
    var targetDayCoverage: Double
    var estimatedEntryShare: Double
    var estimatedCalorieShare: Double?
    var description: String
}

enum FitnessPendingNutritionLabelState: String, Codable, Sendable {
    case pendingUpload = "pending_upload"
    case uploading
    case uploadedWaitingReference = "uploaded_waiting_reference"
    case acknowledged
    case error
}

struct FitnessPendingNutritionLabel: Identifiable, Equatable, Sendable {
    let id: String
    var dependentEntityType: FitnessEntityType
    var dependentEntityId: String
    var originalFilename: String
    var mediaType: String
    var byteCount: Int
    var state: FitnessPendingNutritionLabelState
    var uploadAcknowledged: Bool
    var referenceAcknowledged: Bool
    var attempts: Int
    var lastError: String?
}

struct FitnessNutritionLabelDraft: Equatable, Sendable {
    static let maximumByteCount = 15 * 1_024 * 1_024

    let stagedFile: PhotoUploadPrep.StagedFile
    let originalFilename: String
    let mediaType: String
    let byteCount: Int
    let ownerIdentity: String

    var fileURL: URL { stagedFile.fileURL }
}

struct FitnessFoodBarcodeServing: Codable, Equatable, Sendable {
    let name: String
    let amount: Double
    let unit: String
}

struct FitnessFoodBarcodeLookup: Codable, Equatable, Sendable {
    let barcode: String
    let name: String
    let brand: String?
    let referenceAmount: Double
    let referenceUnit: String
    let nutrients: FitnessNutritionValues
    let serving: FitnessFoodBarcodeServing?
    let source: String
    let sourceUrl: String
    let warnings: [String]
    let needsReview: Bool
}

struct FitnessNutritionMealCompletion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let nutritionDate: String
    let meal: FitnessMeal
    let completedAt: String
    let revision: Int

    private enum CodingKeys: String, CodingKey {
        case id, nutritionDate
        case meal = "mealKey"
        case completedAt, revision
    }
}

struct FitnessNutritionRebucketResult: Codable, Equatable, Sendable {
    let nutritionDayStartMinutes: Int
    let affectedEntries: Int?
    let status: String?
}

struct FitnessFoodMergePreview: Codable, Equatable, Sendable {
    let sourceId: String
    let targetId: String
    let sourceName: String?
    let targetName: String?
    let alreadyMerged: Bool
    let versions: Int
    let servings: Int
    let duplicateServings: Int?
    let affectedLogEntries: Int?
    let affectedRecipeComponents: Int?
    let affectedTemplateItems: Int?
    let warnings: [String]?
}

// MARK: - Consumer first run and household meals

/// An adult's private decision about whether Fitness belongs in their HausKlar
/// workspace and, independently, whether it deserves a permanent tab.
struct FitnessWorkspacePreference: Codable, Equatable, Sendable {
    var enabled: Bool
    var pinned: Bool
    var showNutritionToday: Bool

    private enum CodingKeys: String, CodingKey {
        case enabled, pinned, showNutritionToday
    }

    init(enabled: Bool, pinned: Bool, showNutritionToday: Bool = false) {
        self.enabled = enabled
        self.pinned = pinned
        self.showNutritionToday = showNutritionToday
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        pinned = try container.decode(Bool.self, forKey: .pinned)
        showNutritionToday = try container.decodeIfPresent(
            Bool.self, forKey: .showNutritionToday
        ) ?? false
    }

    static let disabled = Self(enabled: false, pinned: false, showNutritionToday: false)
}

struct FitnessWorkspacePreferenceUpdate: Encodable, Equatable, Sendable {
    var enabled: Bool?
    var pinned: Bool?
    var showNutritionToday: Bool?
}

/// Owner-scoped trigger times for the small Nutrition prompt on Today. These
/// remain local civil times: travelling should move the prompt with the adult,
/// rather than preserving the UTC instant from another timezone.
struct FitnessQuickEntryMealTimes: Codable, Equatable, Sendable {
    var breakfast: String
    var lunch: String
    var dinner: String

    static let defaults = Self(
        breakfast: "08:00",
        lunch: "12:30",
        dinner: "18:30"
    )

    var allValid: Bool {
        [breakfast, lunch, dinner].allSatisfy {
            FitnessQuickEntryPolicy.minuteOfDay(from: $0) != nil
        }
    }

    func value(for meal: FitnessMeal) -> String? {
        switch meal {
        case .breakfast: breakfast
        case .lunch: lunch
        case .dinner: dinner
        default: nil
        }
    }
}

struct FitnessQuickEntryPreferences: Codable, Equatable, Sendable {
    var mealTimes: FitnessQuickEntryMealTimes

    static let defaults = Self(mealTimes: .defaults)
}

struct FitnessQuickEntryPreferencesUpdate: Encodable, Equatable, Sendable {
    let mealTimes: FitnessQuickEntryMealTimes
}

struct FitnessStrengthAvailabilityWindow: Codable, Equatable, Identifiable, Sendable {
    let start: String
    let end: String
    let label: String?
    let bookingUrl: String?

    var id: String { "\(start)|\(end)|\(label ?? "")" }

    var displayLabel: String {
        let times = "\(start)–\(end)"
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return times }
        return "\(label) · \(times)"
    }
}

struct FitnessStrengthAvailabilityDay: Codable, Equatable, Identifiable, Sendable {
    let date: String
    let covered: Bool
    let windows: [FitnessStrengthAvailabilityWindow]

    var id: String { date }
}

/// The server resolves the authenticated adult to exactly one provider. The
/// client never guesses from names or roles, which prevents another adult's
/// private timetable from being inferred or displayed.
struct FitnessStrengthAvailability: Codable, Equatable, Sendable {
    let provider: String
    let sourceTitle: String
    let sourceUrl: String?
    let unavailableReason: String?
    let days: [FitnessStrengthAvailabilityDay]

    var displayTitle: String {
        let value = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Strength timetable".localized : value
    }
}

enum FitnessViClassClassification: String, Codable, CaseIterable, Equatable, Sendable {
    case strength
    case run
    case conditioning
    case mobility
    case other

    var title: String {
        switch self {
        case .strength: "Strength".localized
        case .run: "Run".localized
        case .conditioning: "Conditioning".localized
        case .mobility: "Mobility".localized
        case .other: "Class".localized
        }
    }

    var symbol: String {
        switch self {
        case .strength: "dumbbell.fill"
        case .run: "figure.run"
        case .conditioning: "bolt.heart.fill"
        case .mobility: "figure.flexibility"
        case .other: "figure.mixed.cardio"
        }
    }
}

struct FitnessViClass: Codable, Equatable, Identifiable, Sendable {
    let start: String
    let end: String
    let label: String
    let classification: FitnessViClassClassification
    let bookingUrl: String?

    var id: String { "\(start)|\(end)|\(label)|\(classification.rawValue)" }
    var displayTime: String { "\(start)–\(end)" }
}

struct FitnessViScheduleDay: Codable, Equatable, Identifiable, Sendable {
    let date: String
    let covered: Bool
    let classes: [FitnessViClass]

    var id: String { date }
}

/// The authenticated adult's public Vi timetable. `relevant` is resolved by
/// the server, so iOS never guesses which adult should see the card.
struct FitnessViSchedule: Codable, Equatable, Sendable {
    let relevant: Bool
    let provider: String
    let sourceTitle: String
    let sourceUrl: String?
    let unavailableReason: String?
    let days: [FitnessViScheduleDay]
}

struct FitnessViBookingResponse: Decodable, Equatable, Sendable {
    let status: String
    let eventId: String
    let title: String
    let startTime: String
    let endTime: String
    let location: String
    let classification: FitnessViClassClassification
}

struct FitnessTodayMealPrompt: Equatable, Sendable {
    let meal: FitnessMeal
    let trigger: Date
    let hasEntries: Bool
}

enum FitnessQuickEntryPolicy {
    static let mealPromptRadius: TimeInterval = 90 * 60

    static func minuteOfDay(from value: String) -> Int? {
        let bytes = Array(value.utf8)
        guard bytes.count == 5, bytes[2] == 58,
              bytes[0].isASCIIDigit, bytes[1].isASCIIDigit,
              bytes[3].isASCIIDigit, bytes[4].isASCIIDigit else { return nil }
        let hour = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48)
        let minute = Int(bytes[3] - 48) * 10 + Int(bytes[4] - 48)
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    static func wireTime(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func date(
        for wireTime: String,
        on reference: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let minutes = minuteOfDay(from: wireTime) else { return nil }
        return calendar.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: reference
        )
    }

    static func mealPrompt(
        at now: Date,
        preferences: FitnessQuickEntryPreferences,
        loggedMeals: Set<FitnessMeal>,
        completedMeals: Set<FitnessMeal> = [],
        radius: TimeInterval = mealPromptRadius,
        calendar: Calendar = .current
    ) -> FitnessTodayMealPrompt? {
        let choices: [FitnessTodayMealPrompt] = [
            FitnessMeal.breakfast, .lunch, .dinner,
        ].compactMap { meal in
            guard !completedMeals.contains(meal) else { return nil }
            guard let value = preferences.mealTimes.value(for: meal),
                  let trigger = date(for: value, on: now, calendar: calendar) else {
                return nil
            }
            return FitnessTodayMealPrompt(
                meal: meal,
                trigger: trigger,
                hasEntries: loggedMeals.contains(meal)
            )
        }
        guard let closest = choices.min(by: {
            abs($0.trigger.timeIntervalSince(now)) < abs($1.trigger.timeIntervalSince(now))
        }), abs(closest.trigger.timeIntervalSince(now)) <= radius else { return nil }
        return closest
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { (48...57).contains(self) }
}

enum FitnessOnboardingStatus: String, Codable, Sendable {
    case draft, skipped, complete
}

enum FitnessOnboardingDay: String, Codable, CaseIterable, Identifiable, Sendable {
    case monday = "Monday"
    case tuesday = "Tuesday"
    case wednesday = "Wednesday"
    case thursday = "Thursday"
    case friday = "Friday"
    case saturday = "Saturday"
    case sunday = "Sunday"

    var id: String { rawValue }
    var title: String { rawValue.localized }
    var sortOrder: Int {
        switch self {
        case .monday: 0
        case .tuesday: 1
        case .wednesday: 2
        case .thursday: 3
        case .friday: 4
        case .saturday: 5
        case .sunday: 6
        }
    }
    var shortTitle: String {
        switch self {
        case .monday: "Mon".localized
        case .tuesday: "Tue".localized
        case .wednesday: "Wed".localized
        case .thursday: "Thu".localized
        case .friday: "Fri".localized
        case .saturday: "Sat".localized
        case .sunday: "Sun".localized
        }
    }
}

enum FitnessOnboardingTimeOfDay: String, Codable, CaseIterable, Identifiable, Sendable {
    case morning = "Morning"
    case lunchtime = "Lunchtime"
    case evening = "Evening"
    case flexible = "Flexible"

    var id: String { rawValue }
    var title: String { rawValue.localized }
}

enum FitnessOnboardingOutcome: String, Codable, CaseIterable, Identifiable, Sendable {
    case feelFitter = "Feel fitter"
    case buildStrength = "Build strength"
    case runFurther = "Run further"
    case improveEnergy = "Improve energy"
    case supportWeight = "Support my weight"
    case moveConsistently = "Move consistently"

    var id: String { rawValue }
    var title: String { rawValue.localized }
}

enum FitnessOverviewFactKind: Equatable, Sendable {
    case movement, strength, running, energy, weight
}

struct FitnessOverviewFactSnapshot: Equatable, Sendable {
    var activeDays: Int
    var strengthSessions: Int
    var runningSessions: Int
    var runningDistanceMetres: Double
    var averageSleepSeconds: Double?
    var weightKilograms: Double?
}

struct FitnessOverviewFactContent: Equatable, Sendable {
    let kind: FitnessOverviewFactKind
    let label: String
    let value: String
    let detail: String?
}

/// Keeps the quiet summary on the outcome the adult chose. Nutrition and body
/// weight never become the default language of Fitness unless weight support was
/// explicitly selected.
enum FitnessOverviewFactPolicy {
    static func fact(
        outcome: FitnessOnboardingOutcome?,
        snapshot: FitnessOverviewFactSnapshot
    ) -> FitnessOverviewFactContent {
        switch outcome ?? .moveConsistently {
        case .buildStrength:
            return .init(
                kind: .strength,
                label: "Strength this week".localized,
                value: sessionLabel(snapshot.strengthSessions),
                detail: "Completed strength sessions".localized
            )
        case .runFurther:
            let distance = snapshot.runningDistanceMetres / 1_000
            return .init(
                kind: .running,
                label: "Running this week".localized,
                value: distance > 0
                    ? distance.formatted(.number.precision(.fractionLength(0...1))) + " km"
                    : sessionLabel(snapshot.runningSessions),
                detail: distance > 0
                    ? sessionLabel(snapshot.runningSessions)
                    : "Completed runs".localized
            )
        case .improveEnergy:
            if let sleep = snapshot.averageSleepSeconds {
                return .init(
                    kind: .energy,
                    label: "Average sleep".localized,
                    value: durationLabel(sleep),
                    detail: "Across your current recovery window".localized
                )
            }
            return activeDaysFact(snapshot.activeDays, kind: .energy)
        case .supportWeight:
            return .init(
                kind: .weight,
                label: "Weight support".localized,
                value: snapshot.weightKilograms.map {
                    $0.formatted(.number.precision(.fractionLength(1))) + " kg"
                } ?? "No measurement yet".localized,
                detail: snapshot.weightKilograms == nil
                    ? "Add one only when it is useful to you.".localized
                    : "Current seven-day trend".localized
            )
        case .feelFitter, .moveConsistently:
            return activeDaysFact(snapshot.activeDays, kind: .movement)
        }
    }

    private static func activeDaysFact(
        _ count: Int,
        kind: FitnessOverviewFactKind
    ) -> FitnessOverviewFactContent {
        .init(
            kind: kind,
            label: "Movement this week".localized,
            value: count == 1
                ? "1 active day".localized
                : String(format: "%lld active days".localized, Int64(count)),
            detail: "Any recorded activity counts".localized
        )
    }

    private static func sessionLabel(_ count: Int) -> String {
        count == 1
            ? "1 session".localized
            : String(format: "%lld sessions".localized, Int64(count))
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0
            ? String(format: "%lld hr".localized, Int64(hours))
            : String(
                format: "%lld hr %lld min".localized,
                Int64(hours),
                Int64(minutes)
            )
    }
}

enum FitnessOnboardingActivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case walking = "Walking"
    case running = "Running"
    case strength = "Strength"
    case cycling = "Cycling"
    case swimming = "Swimming"
    case mobility = "Mobility"

    var id: String { rawValue }
    var title: String { rawValue.localized }
}

enum FitnessOnboardingSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleHealth = "Apple Health"
    case garmin = "Garmin"
    case withings = "Withings"
    case intervals = "Intervals.icu"

    var id: String { rawValue }
}

enum FitnessOnboardingCoachStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case calm = "Calm and encouraging"
    case balanced = "Balanced and practical"
    case direct = "Direct and challenging"

    var id: String { rawValue }
}

struct FitnessOnboardingAvailability: Codable, Equatable, Identifiable, Sendable {
    var day: FitnessOnboardingDay
    var timeOfDay: FitnessOnboardingTimeOfDay
    var durationMinutes: Int

    var id: FitnessOnboardingDay { day }
}

struct FitnessOnboardingWeekSession: Codable, Equatable, Identifiable, Sendable {
    let day: FitnessOnboardingDay
    let date: String
    let startTime: String
    let activity: FitnessOnboardingActivity
    let title: String
    let durationMinutes: Int
    let reason: String

    var id: String { "\(date)-\(startTime)-\(activity.rawValue)" }
}

struct FitnessOnboardingWeekPreview: Codable, Equatable, Identifiable, Sendable {
    let previewId: String
    let weekStart: String
    let summary: String
    let sessions: [FitnessOnboardingWeekSession]

    var id: String { previewId }
}

struct FitnessOnboardingConfirmation: Codable, Equatable, Sendable {
    let completedAt: String
    let goalId: String
    let sessionIds: [String]
}

struct FitnessOnboardingProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var status: FitnessOnboardingStatus
    var mainOutcome: FitnessOnboardingOutcome?
    var availability: [FitnessOnboardingAvailability]
    var activities: [FitnessOnboardingActivity]
    var equipment: [String]
    var foodPreferences: [String]
    var sourceConnections: [FitnessOnboardingSource]
    var coachStyle: FitnessOnboardingCoachStyle?
    var useFamilyCalendar: Bool
    var useHouseholdMeals: Bool
    var useWeather: Bool
    var memoryEnabled: Bool
    var preview: FitnessOnboardingWeekPreview?
    var confirmation: FitnessOnboardingConfirmation?
}

struct FitnessOnboardingDraft: Codable, Equatable, Sendable {
    var mainOutcome: FitnessOnboardingOutcome?
    var availability: [FitnessOnboardingAvailability]
    var activities: [FitnessOnboardingActivity]
    var equipment: [String]
    var foodPreferences: [String]
    var sourceConnections: [FitnessOnboardingSource]
    var coachStyle: FitnessOnboardingCoachStyle?
    var useFamilyCalendar: Bool
    var useHouseholdMeals: Bool
    var useWeather: Bool
    var memoryEnabled: Bool
    var clientId: String?
    var clientTimestamp: String?

    init(profile: FitnessOnboardingProfile, clientId: String? = nil) {
        mainOutcome = profile.mainOutcome
        availability = profile.availability
        activities = profile.activities
        equipment = profile.equipment
        foodPreferences = profile.foodPreferences
        sourceConnections = profile.sourceConnections
        coachStyle = profile.coachStyle
        useFamilyCalendar = profile.useFamilyCalendar
        useHouseholdMeals = profile.useHouseholdMeals
        useWeather = profile.useWeather
        memoryEnabled = profile.memoryEnabled
        self.clientId = clientId
        clientTimestamp = FitnessDatabase.dateString(Date())
    }
}

struct FitnessOnboardingConfirmResponse: Codable, Equatable, Sendable {
    let status: FitnessOnboardingStatus
    let completedAt: String
    let goalId: String
    let sessionIds: [String]
    let week: FitnessOnboardingWeekPreview
}

struct FitnessHouseholdMealLink: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let mealId: String
    let mealName: String
    let recipeId: String
    let recipeVersionId: String
    let recipeName: String
    let linkedAt: String
}

struct FitnessHouseholdMeal: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

enum FitnessPlannedMealUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case serving, g
    var id: String { rawValue }
    var title: String { self == .g ? "g" : "serving" }
}

struct FitnessPlannedHouseholdMeal: Codable, Equatable, Identifiable, Sendable {
    let mealPlanId: String
    let date: String
    let mealType: FitnessMeal
    let mealId: String
    let mealName: String
    let linkId: String
    let recipeId: String
    let recipeVersionId: String
    let recipeName: String
    let suggestedPortion: Double
    let suggestedUnit: FitnessPlannedMealUnit

    var id: String { mealPlanId }
}

struct FitnessPlannedMealLogDraft: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let mealPlanId: String
    let mealName: String
    let recipeName: String
    let recipeVersionId: String
    let mealType: FitnessMeal
    var portion: Double
    var unit: FitnessPlannedMealUnit
    let loggedAtUtc: String
    let localTimezone: String
    var notes: String?
    let clientId: String?
    let clientTimestamp: String?

    init(
        id: String = UUID().uuidString,
        plannedMeal: FitnessPlannedHouseholdMeal,
        portion: Double? = nil,
        unit: FitnessPlannedMealUnit? = nil,
        loggedAt: Date = Date(),
        localTimezone: String = TimeZone.current.identifier,
        notes: String? = nil,
        clientId: String? = nil
    ) {
        self.id = id
        mealPlanId = plannedMeal.mealPlanId
        mealName = plannedMeal.mealName
        recipeName = plannedMeal.recipeName
        recipeVersionId = plannedMeal.recipeVersionId
        mealType = plannedMeal.mealType
        self.portion = portion ?? plannedMeal.suggestedPortion
        self.unit = unit ?? plannedMeal.suggestedUnit
        loggedAtUtc = FitnessDatabase.dateString(loggedAt)
        self.localTimezone = localTimezone
        self.notes = notes
        self.clientId = clientId
        clientTimestamp = FitnessDatabase.dateString(Date())
    }
}

struct FitnessPrivatePlannedMealLog: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let sourceMealPlanId: String
    let householdMealLinkId: String
    let recipeVersionId: String
    let nutritionDate: String
    let mealType: FitnessMeal
    let loggedAtUtc: String
    let portion: Double
    let unit: FitnessPlannedMealUnit
    let caloriesKcal: Double?
    let proteinG: Double?
}

enum FitnessCapturePolicy {
    static let requiresOnDeviceSpeechRecognition=true
    static let photoRemainsLocalDraft=true

    static func canSaveReviewedText(_ text:String) -> Bool {
        !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
}

enum FitnessLogAccessibilityTarget:Equatable {
    case none, undo

    static func afterQuickLog(entryId:String?) -> Self {
        entryId == nil ? .none : .undo
    }
}

enum FitnessOnboardingCommitPolicy {
    enum Stage { case choiceDraft, preview, confirmation }
    static let choiceStepCount=3
    static let totalSetupStepCount=4

    static func canConfirm(preview:FitnessOnboardingWeekPreview?) -> Bool {
        preview != nil
    }

    static func createsGoalOrSessions(at stage:Stage) -> Bool {
        stage == .confirmation
    }

    static func presentsAutomatically(status:FitnessOnboardingStatus?) -> Bool {
        status == .draft
    }

    static func offersFinishLater(status:FitnessOnboardingStatus?) -> Bool {
        status == .skipped
    }
}

enum FitnessOnboardingAccessibilityTarget:Hashable {
    case heading(step:Int)

    static func afterTransition(choiceStep:Int,hasPreview:Bool) -> Self {
        if hasPreview {
            return .heading(step:FitnessOnboardingCommitPolicy.totalSetupStepCount)
        }
        let boundedStep=min(
            max(choiceStep,0),FitnessOnboardingCommitPolicy.choiceStepCount-1
        )
        return .heading(step:boundedStep+1)
    }
}

enum FitnessPlannedMealShortcutPolicy {
    static func isVisible(plannedMealCount:Int,useMealPlanForCoach:Bool) -> Bool {
        // Coach context is a separate privacy choice. The adult's explicit Log
        // shortcut remains available whenever there is a linked planned meal.
        plannedMealCount > 0
    }
}
