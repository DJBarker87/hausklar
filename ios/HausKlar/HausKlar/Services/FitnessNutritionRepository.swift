import Foundation
import GRDB
import os

private let fitnessNutritionRepositoryLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessNutritionRepository"
)

enum FitnessNutritionRepositoryError: LocalizedError {
    case invalidFood
    case invalidVersion
    case invalidServing
    case invalidLog
    case invalidRecipe
    case invalidTemplate
    case invalidTarget
    case missingRecord
    case invalidLabel
    case unsafePath
    case inactiveProfile

    var errorDescription: String? {
        switch self {
        case .invalidFood: "Enter a food name."
        case .invalidVersion: "Enter a positive reference amount and a complete energy source."
        case .invalidServing: "Enter a positive serving and canonical amount."
        case .invalidLog: "Choose one saved food or recipe version and a positive amount."
        case .invalidRecipe: "A recipe needs a name and at least one valid component."
        case .invalidTemplate: "A meal template needs a name and at least one valid item."
        case .invalidTarget: "Complete the values required for this target type."
        case .missingRecord: "That saved Nutrition record is no longer available."
        case .invalidLabel: "Choose a JPEG, PNG, HEIC, or HEIF nutrition-label image no larger than 15 MB."
        case .unsafePath: "HausKlar refused a private file outside this Fitness profile."
        case .inactiveProfile: "Open Fitness again in the current profile."
        }
    }
}

struct FitnessFoodVersionDraft: Equatable, Sendable {
    var referenceAmount: Double = 100
    var referenceUnit: String = "g"
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
    var micronutrients: [String: Double?] = [:]
    var sourceType: String = "manual"
    var sourceNote: String?
    var confidence: String = "measured"
}

struct FitnessFoodDraft: Equatable, Sendable {
    var name: String
    var brand: String?
    var categoryKey: String?
    var barcode: String?
    var notes: String?
    var householdShared: Bool
    var favourite: Bool
    var version: FitnessFoodVersionDraft
}

struct FitnessFoodServingDraft: Equatable, Sendable {
    var name: String
    var amount: Double
    var unit: String
    var canonicalAmount: Double
    var canonicalUnit: String
    var measurementQuality: FitnessNutritionMeasurementQuality
    var isDefault: Bool
}

struct FitnessFoodLogDraft: Equatable, Sendable {
    var foodVersionId: String?
    var recipeVersionId: String?
    var label: String
    var loggedAt: Date
    var localTimezone: String
    var meal: FitnessMeal
    var enteredAmount: Double
    var enteredUnit: String
    var canonicalAmount: Double
    var canonicalUnit: String
    var measurementQuality: FitnessNutritionMeasurementQuality
    var notes: String?
    var contextTags: [String]
}

struct FitnessRecipeDraft: Equatable, Sendable {
    var name: String
    var notes: String?
    var householdShared: Bool
    var favourite: Bool
    var components: [FitnessRecipeComponent]
    var finishedWeightG: Double?
    var servings: Double?
    var caloriesKcal: Double?
    var lowerCaloriesKcal: Double?
    var upperCaloriesKcal: Double?
    var confidence: String
    var sourceNote: String?
}

actor FitnessNutritionRepository {
    static let shared = FitnessNutritionRepository()

    private let database: FitnessDatabase
    private let injectedDeviceId: String?
    private var deviceId: String {
        get throws {
            if let injectedDeviceId { return injectedDeviceId }
            return try APIClient.shared.clientId
        }
    }
    private let fileManager: FileManager
    private let currentTimeZone: @Sendable () -> TimeZone
    private let beforeLabelFilePublication: (@Sendable () throws -> Void)?
    private let beforeLabelDatabaseCommit: (@Sendable () throws -> Void)?
    private let encoder: JSONEncoder

    private struct StagedPrivateLabel {
        let ownerIdentity: String
        let profileRoot: URL
        let relativePath: String
        let originalFilename: String
        let mediaType: String
        let byteCount: Int
    }

    init(
        database: FitnessDatabase = .shared,
        deviceId: String? = nil,
        fileManager: FileManager = .default,
        currentTimeZone: @escaping @Sendable () -> TimeZone = { .current },
        beforeLabelFilePublication: (@Sendable () throws -> Void)? = nil,
        beforeLabelDatabaseCommit: (@Sendable () throws -> Void)? = nil
    ) {
        self.database = database
        self.injectedDeviceId = deviceId
        self.fileManager = fileManager
        self.currentTimeZone = currentTimeZone
        self.beforeLabelFilePublication = beforeLabelFilePublication
        self.beforeLabelDatabaseCommit = beforeLabelDatabaseCommit
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FitnessDatabase.dateString(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    // MARK: Read model

    func settings() throws -> FitnessNutritionSettings {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM fitness_nutrition_settings WHERE deleted_at IS NULL LIMIT 1"
            ) else {
                return FitnessNutritionSettings(
                    id: "nutrition-settings", timezone: TimeZone.current.identifier,
                    nutritionDayStartMinutes: 240, revision: 0
                )
            }
            return FitnessNutritionSettings(
                id: row["id"], timezone: row["timezone"] ?? TimeZone.current.identifier,
                nutritionDayStartMinutes: min(max(row["nutrition_day_start_minutes"] ?? 240, 0), 480),
                heartRateZoneBoundariesBpm: try Self.integerArray(
                    row["heart_rate_zone_boundaries_json"]
                ),
                revision: row["revision"]
            )
        }
    }

    func foods(search: String = "", includeArchived: Bool = false) throws -> [FitnessFood] {
        try database.read { db in
            let term = "%\(search.trimmingCharacters(in: .whitespacesAndNewlines))%"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_foods
                    WHERE deleted_at IS NULL AND (? OR active=1)
                      AND (?='%%' OR name LIKE ? OR COALESCE(brand,'') LIKE ?
                           OR COALESCE(category_key,'') LIKE ? OR COALESCE(barcode,'') LIKE ?)
                    ORDER BY is_favourite DESC,name COLLATE NOCASE
                    """,
                arguments: [includeArchived,term,term,term,term,term]
            )
            return try foods(rows: rows,db: db)
        }
    }

    func recipes(includeArchived: Bool = false) throws -> [FitnessRecipe] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_recipes WHERE deleted_at IS NULL AND (? OR active=1)
                    ORDER BY favourite DESC,name COLLATE NOCASE
                """,
                arguments: [includeArchived]
            )
            guard !rows.isEmpty else { return [] }
            let recipeIds: [String] = rows.map { $0["id"] }
            let placeholders = Array(repeating: "?",count: recipeIds.count).joined(separator: ",")
            let versionRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_recipe_versions
                    WHERE recipe_id IN (\(placeholders)) AND deleted_at IS NULL
                    ORDER BY recipe_id,version_number DESC
                    """,
                arguments: StatementArguments(recipeIds)
            )
            var versionsByRecipe: [String: [FitnessRecipeVersion]] = [:]
            for versionRow in versionRows {
                let version = try recipeVersion(versionRow)
                versionsByRecipe[version.recipeId,default: []].append(version)
            }
            return rows.map { row in
                let id: String = row["id"]
                return recipe(row: row,versions: versionsByRecipe[id] ?? [])
            }
        }
    }

    func mealTemplates(includeArchived: Bool = false) throws -> [FitnessMealTemplate] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_meal_templates WHERE deleted_at IS NULL AND (? OR active=1)
                    ORDER BY favourite DESC,name COLLATE NOCASE
                    """,
                arguments: [includeArchived]
            ).map { try template($0) }
        }
    }

    func nutritionTargets(includeArchived: Bool = false) throws -> [FitnessNutritionTarget] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_nutrition_targets WHERE deleted_at IS NULL AND (? OR active=1)
                    ORDER BY effective_from DESC,metric_key
                    """,
                arguments: [includeArchived]
            ).compactMap(target)
        }
    }

    func day(on date: Date = Date()) throws -> FitnessNutritionDay {
        let currentSettings = try settings()
        var calendar = Calendar(identifier: .gregorian)
        // The active diary day follows the device while travelling. Each entry
        // still keeps the timezone in which it was logged for audit/rebucketing.
        calendar.timeZone = currentTimeZone()
        let nutritionDate = FitnessCalculations.nutritionDate(
            for: date, dayStartMinutes: currentSettings.nutritionDayStartMinutes, calendar: calendar
        )
        return try day(nutritionDate: nutritionDate)
    }

    func day(nutritionDate: String) throws -> FitnessNutritionDay {
        try database.read { db in
            let entries = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_food_log_entries
                    WHERE nutrition_date=? AND deleted_at IS NULL ORDER BY logged_at DESC
                    """,
                arguments: [nutritionDate]
            ).map { try logEntry($0) }
            let totals = FitnessNutritionValues.exactTotal(entries.map(\.nutrients))
            let uncertain = Set(FitnessNutritionMetric.allCases.filter { metric in
                entries.contains { nutrient($0.nutrients,metric: metric) == nil }
            })
            let knownCalories = entries.compactMap(\.kcal).reduce(0,+)
            let estimatedCalories = entries.filter { $0.measurementQuality.isEstimate }.compactMap(\.kcal).reduce(0,+)
            return FitnessNutritionDay(
                nutritionDate: nutritionDate, entries: entries, totals: totals,
                uncertainMetrics: uncertain,
                measuredShare: knownCalories > 0 ? (knownCalories-estimatedCalories)/knownCalories : nil,
                estimatedShare: knownCalories > 0 ? estimatedCalories/knownCalories : nil
            )
        }
    }

    func pendingLabels() throws -> [FitnessPendingNutritionLabel] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_private_file_uploads
                    WHERE asset_kind='nutrition_label' ORDER BY created_at
                    """
            ).compactMap { row in
                guard let type = FitnessEntityType(rawValue: row["dependent_entity_type"] ?? "") else { return nil }
                return FitnessPendingNutritionLabel(
                    id: row["asset_id"],dependentEntityType: type,
                    dependentEntityId: row["domain_entity_id"],originalFilename: row["original_filename"],
                    mediaType: row["media_type"],byteCount: row["byte_count"],
                    state: FitnessPendingNutritionLabelState(rawValue: row["state"]) ?? .error,
                    uploadAcknowledged: (row["upload_acknowledged"] as Int) != 0,
                    referenceAcknowledged: (row["metadata_acknowledged"] as Int) != 0,
                    attempts: row["attempt_count"],lastError: row["last_error"]
                )
            }
        }
    }

    // MARK: Consumer experience cache and specialised offline work

    func cacheOnboarding(_ profile: FitnessOnboardingProfile) throws {
        try cache(profile,key: "onboarding")
    }

    func cachedOnboarding() throws -> FitnessOnboardingProfile? {
        try cached(FitnessOnboardingProfile.self,key: "onboarding")
    }

    func cacheGoalTemplates(_ templates: [FitnessGoalTemplate]) throws {
        try cache(templates,key: "goal-templates")
    }

    func cachedGoalTemplates() throws -> [FitnessGoalTemplate] {
        try cached([FitnessGoalTemplate].self,key: "goal-templates") ?? []
    }

    func cacheWeeklyReview(_ review: FitnessWeeklyReview) throws {
        try cache(review,key: "weekly-review:\(review.weekStart)")
    }

    func cachedWeeklyReview(weekStart: String) throws -> FitnessWeeklyReview? {
        try cached(FitnessWeeklyReview.self,key: "weekly-review:\(weekStart)")
    }

    func cacheProgressCharts(_ charts: FitnessProgressChartsDTO) throws {
        try cache(charts,key: "progress-charts")
    }

    func cachedProgressCharts() throws -> FitnessProgressChartsDTO? {
        try cached(FitnessProgressChartsDTO.self,key: "progress-charts")
    }

    func cachePlannedMeals(_ meals: [FitnessPlannedHouseholdMeal],date: String) throws {
        try cache(meals,key: "planned-meals:\(date)")
    }

    func cachedPlannedMeals(date: String) throws -> [FitnessPlannedHouseholdMeal] {
        try cached([FitnessPlannedHouseholdMeal].self,key: "planned-meals:\(date)") ?? []
    }

    func cacheHouseholdMealLinks(_ links: [FitnessHouseholdMealLink]) throws {
        try cache(links,key: "household-meal-links")
    }

    func cachedHouseholdMealLinks() throws -> [FitnessHouseholdMealLink] {
        try cached([FitnessHouseholdMealLink].self,key: "household-meal-links") ?? []
    }

    func cacheQuickEntryPreferences(_ value: FitnessQuickEntryPreferences) throws {
        try cache(value, key: "quick-entry-preferences")
    }

    func cachedQuickEntryPreferences() throws -> FitnessQuickEntryPreferences? {
        try cached(FitnessQuickEntryPreferences.self, key: "quick-entry-preferences")
    }

    func cacheMealCompletions(
        _ value: [FitnessNutritionMealCompletion],
        date: String
    ) throws {
        try cache(value, key: "meal-completions:\(date)")
    }

    func cachedMealCompletions(date: String) throws -> [FitnessNutritionMealCompletion]? {
        try cached(
            [FitnessNutritionMealCompletion].self,
            key: "meal-completions:\(date)"
        )
    }

    func cacheStrengthAvailability(
        _ value: FitnessStrengthAvailability,
        start: String,
        end: String
    ) throws {
        try cache(value, key: "strength-availability:\(start):\(end)")
    }

    func cachedStrengthAvailability(
        start: String,
        end: String
    ) throws -> FitnessStrengthAvailability? {
        try cached(
            FitnessStrengthAvailability.self,
            key: "strength-availability:\(start):\(end)"
        )
    }

    func cacheViSchedule(
        _ value: FitnessViSchedule,
        start: String,
        end: String
    ) throws {
        try cache(value, key: "vi-schedule:\(start):\(end)")
    }

    func cachedViSchedule(
        start: String,
        end: String
    ) throws -> FitnessViSchedule? {
        try cached(
            FitnessViSchedule.self,
            key: "vi-schedule:\(start):\(end)"
        )
    }

    func markPlannedMealLogged(mealPlanId: String) throws {
        try cache(true,key:"planned-meal-logged:\(mealPlanId)")
    }

    /// Commits the server acknowledgement and removes its outbox entry in one
    /// transaction. A failed cache write therefore cannot strand an
    /// acknowledged meal without its durable local completion marker.
    func acknowledgePlannedMealLog(id: String,mealPlanId: String) throws {
        let owner = try requireOwnerIdentity()
        let key = "planned-meal-logged:\(mealPlanId)"
        let payload = try json(true)
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_experience_cache(owner_identity,cache_key,payload_json,updated_at)
                    VALUES (?,?,?,?)
                    ON CONFLICT(owner_identity,cache_key) DO UPDATE SET
                      payload_json=excluded.payload_json,updated_at=excluded.updated_at
                    """,
                arguments: [owner,key,payload,now]
            )
            try db.execute(
                sql: "DELETE FROM fitness_planned_meal_outbox WHERE id=? AND owner_identity=?",
                arguments: [id,owner]
            )
        }
    }

    func loggedPlannedMealIds() throws -> Set<String> {
        let owner=try requireOwnerIdentity()
        return try database.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                    SELECT cache_key FROM fitness_experience_cache
                    WHERE owner_identity=? AND cache_key LIKE 'planned-meal-logged:%'
                    """,
                arguments:[owner]
            ).map { String($0.dropFirst("planned-meal-logged:".count)) })
        }
    }

    func enqueuePlannedMealLog(_ draft: FitnessPlannedMealLogDraft) throws {
        guard draft.portion.isFinite,draft.portion > 0 else {
            throw FitnessNutritionRepositoryError.invalidLog
        }
        let owner = try requireOwnerIdentity()
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_planned_meal_outbox
                    (id,owner_identity,meal_plan_id,payload_json,created_at,attempt_count,last_attempt_at,last_error)
                    VALUES (?,?,?,?,?,0,NULL,NULL)
                    ON CONFLICT(id) DO UPDATE SET
                      owner_identity=excluded.owner_identity,
                      meal_plan_id=excluded.meal_plan_id,
                      payload_json=excluded.payload_json,
                      last_error=NULL
                    """,
                arguments: [draft.id,owner,draft.mealPlanId,try json(draft),now]
            )
        }
    }

    func pendingPlannedMealLogs() throws -> [FitnessPlannedMealLogDraft] {
        let owner = try requireOwnerIdentity()
        return try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT payload_json FROM fitness_planned_meal_outbox
                    WHERE owner_identity=? ORDER BY created_at,id
                    """,
                arguments: [owner]
            ).map { row in
                guard let draft = try decode(
                    FitnessPlannedMealLogDraft.self,row["payload_json"]
                ) else {
                    throw FitnessNutritionRepositoryError.missingRecord
                }
                return draft
            }
        }
    }

    func markPlannedMealAttempt(id: String,error: String?) throws {
        let owner = try requireOwnerIdentity()
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_planned_meal_outbox
                    SET attempt_count=attempt_count+1,last_attempt_at=?,last_error=?
                    WHERE id=? AND owner_identity=?
                    """,
                arguments: [FitnessDatabase.dateString(Date()),error,id,owner]
            )
        }
    }

    func removePendingPlannedMealLog(id: String) throws {
        let owner = try requireOwnerIdentity()
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM fitness_planned_meal_outbox WHERE id=? AND owner_identity=?",
                arguments: [id,owner]
            )
        }
    }

    func setQuickLogUndo(_ entry: FitnessFoodLogEntry) throws {
        let owner = try requireOwnerIdentity()
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_log_undo(owner_identity,entry_id,created_at)
                    VALUES (?,?,?)
                    ON CONFLICT(owner_identity) DO UPDATE SET
                      entry_id=excluded.entry_id,created_at=excluded.created_at
                    """,
                arguments: [owner,entry.id,FitnessDatabase.dateString(Date())]
            )
        }
    }

    func quickLogUndo() throws -> FitnessFoodLogEntry? {
        let owner = try requireOwnerIdentity()
        return try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT l.* FROM fitness_log_undo u
                    JOIN fitness_food_log_entries l ON l.id=u.entry_id
                    WHERE u.owner_identity=? AND l.deleted_at IS NULL
                    """,
                arguments: [owner]
            ) else { return nil }
            return try logEntry(row)
        }
    }

    func clearQuickLogUndo(entryId: String? = nil) throws {
        let owner = try requireOwnerIdentity()
        try database.write { db in
            if let entryId {
                try db.execute(
                    sql: "DELETE FROM fitness_log_undo WHERE owner_identity=? AND entry_id=?",
                    arguments: [owner,entryId]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM fitness_log_undo WHERE owner_identity=?",
                    arguments: [owner]
                )
            }
        }
    }

    // MARK: Food library

    @discardableResult
    func createFood(_ draft: FitnessFoodDraft,label: FitnessNutritionLabelDraft? = nil) throws -> FitnessFood {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FitnessNutritionRepositoryError.invalidFood }
        try validate(version: draft.version)
        let now = Date()
        let foodId = UUID().uuidString
        let versionId = UUID().uuidString
        let assetId = label.map { _ in UUID().uuidString }
        let version = makeVersion(
            id: versionId,foodId: foodId,versionNumber: 1,draft: draft.version,
            labelAssetId: assetId,now: now
        )
        let food = FitnessFood(
            id: foodId,versionId: versionId,name: name,brand: trimmed(draft.brand),
            kcalPer100g: per100Calories(version),defaultServingGrams: nil,
            isFavourite: draft.favourite,isArchived: false,revision: 0,updatedAt: now,
            categoryKey: trimmed(draft.categoryKey),barcode: trimmed(draft.barcode),
            notes: trimmed(draft.notes),householdShared: draft.householdShared,active: true,
            versions: [version]
        )
        let mutationId = UUID().uuidString
        let request = FoodMutation(
            id: foodId,name: name,brand: food.brand,categoryKey: food.categoryKey,
            barcode: food.barcode,notes: food.notes,householdShared: food.householdShared,
            favourite: food.isFavourite,active: true,version: FoodVersionMutation(version: version,includeFoodId: false)
        )
        let staged: StagedPrivateLabel?
        if let label, let assetId {
            staged = try stageLabel(label,assetId: assetId)
        } else {
            staged = nil
        }
        do {
            if let staged {
                try Task.checkCancellation()
                try beforeLabelDatabaseCommit?()
                try validateLabelCommitContext(staged)
            }
            let commit: (Database) throws -> Void = { db in
                try self.upsert(food: food,db: db)
                try self.upsert(version: version,db: db)
                try self.enqueue(
                    db,mutationId: mutationId,type: .food,id: foodId,
                    baseRevision: nil,payload: request,now: now
                )
                if let staged, let assetId {
                    try self.insertPendingLabel(
                        db,assetId: assetId,entityType: .food,entityId: foodId,
                        mutationId: mutationId,staged: staged,now: now
                    )
                }
            }
            if let staged {
                try database.writeCurrent(identity: staged.ownerIdentity,commit)
            } else {
                try database.write(commit)
            }
        } catch {
            // A protected file written before SQLite commit is intentionally retained;
            // reconciliation can identify it without risking the user's only copy.
            throw error
        }
        return food
    }

    @discardableResult
    func addFoodVersion(
        foodId: String,draft: FitnessFoodVersionDraft,label: FitnessNutritionLabelDraft? = nil
    ) throws -> FitnessFoodVersion {
        try validate(version: draft)
        let now = Date()
        let versionId = UUID().uuidString
        let assetId = label.map { _ in UUID().uuidString }
        let versionNumber: Int = try database.read { db in
            (try Int.fetchOne(
                db,sql: "SELECT COALESCE(MAX(version_number),0)+1 FROM fitness_food_versions WHERE food_id=?",
                arguments: [foodId]
            )) ?? 1
        }
        let version = makeVersion(
            id: versionId,foodId: foodId,versionNumber: versionNumber,draft: draft,
            labelAssetId: assetId,now: now
        )
        let mutationId = UUID().uuidString
        let request = FoodVersionMutation(version: version,includeFoodId: true)
        let staged: StagedPrivateLabel?
        if let label, let assetId {
            staged = try stageLabel(label,assetId: assetId)
        } else {
            staged = nil
        }
        if let staged {
            try Task.checkCancellation()
            try beforeLabelDatabaseCommit?()
            try validateLabelCommitContext(staged)
        }
        let commit: (Database) throws -> Void = { db in
            guard try Bool.fetchOne(
                db,sql: "SELECT EXISTS(SELECT 1 FROM fitness_foods WHERE id=? AND deleted_at IS NULL)",
                arguments: [foodId]
            ) == true else { throw FitnessNutritionRepositoryError.missingRecord }
            try self.upsert(version: version,db: db)
            try db.execute(
                sql: "UPDATE fitness_foods SET current_version_id=?,client_updated_at=? WHERE id=?",
                arguments: [versionId,FitnessDatabase.dateString(now),foodId]
            )
            try self.enqueue(
                db,mutationId: mutationId,type: .foodVersion,id: versionId,
                baseRevision: nil,payload: request,now: now
            )
            if let staged, let assetId {
                try self.insertPendingLabel(
                    db,assetId: assetId,entityType: .foodVersion,entityId: versionId,
                    mutationId: mutationId,staged: staged,now: now
                )
            }
        }
        if let staged {
            try database.writeCurrent(identity: staged.ownerIdentity,commit)
        } else {
            try database.write(commit)
        }
        return version
    }

    @discardableResult
    func saveFoodIdentity(_ food: FitnessFood) throws -> FitnessFood {
        let now = Date()
        let request = FoodMutation(
            id: food.id,name: food.name,brand: food.brand,categoryKey: food.categoryKey,
            barcode: food.barcode,notes: food.notes,householdShared: food.householdShared,
            favourite: food.isFavourite,active: food.active,version: nil
        )
        try database.write { db in
            try upsert(food: food,db: db)
            try enqueue(
                db,type: .food,id: food.id,baseRevision: food.revision,payload: request,now: now
            )
        }
        return food
    }

    @discardableResult
    func addServing(foodId: String,draft: FitnessFoodServingDraft) throws -> FitnessFoodServing {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.amount.isFinite,draft.amount > 0,
              draft.canonicalAmount.isFinite,draft.canonicalAmount > 0,
              !draft.unit.isEmpty,!draft.canonicalUnit.isEmpty else {
            throw FitnessNutritionRepositoryError.invalidServing
        }
        let now = Date()
        let serving = FitnessFoodServing(
            id: UUID().uuidString,foodId: foodId,name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: draft.amount,unit: draft.unit,canonicalAmount: draft.canonicalAmount,
            canonicalUnit: draft.canonicalUnit,measurementQuality: draft.measurementQuality,
            isDefault: draft.isDefault,active: true,revision: 0,updatedAt: now,deletedAt: nil
        )
        let request = FoodServingMutation(serving: serving)
        try database.write { db in
            if serving.isDefault {
                try db.execute(sql: "UPDATE fitness_food_servings SET is_default=0 WHERE food_id=?",arguments: [foodId])
            }
            try upsert(serving: serving,db: db)
            try enqueue(db,type: .foodServing,id: serving.id,baseRevision: nil,payload: request,now: now)
        }
        return serving
    }

    // MARK: Diary and quick reuse

    @discardableResult
    func saveLog(
        _ draft: FitnessFoodLogDraft,
        id: String = UUID().uuidString,
        baseRevision: Int? = nil
    ) throws -> FitnessFoodLogEntry {
        guard (draft.foodVersionId == nil) != (draft.recipeVersionId == nil),
              draft.enteredAmount.isFinite,draft.enteredAmount > 0,
              draft.canonicalAmount.isFinite,draft.canonicalAmount > 0,
              !draft.enteredUnit.isEmpty,!draft.canonicalUnit.isEmpty else {
            throw FitnessNutritionRepositoryError.invalidLog
        }
        let now = Date()
        return try database.write { db in
            let source = try sourceSnapshot(
                foodVersionId: draft.foodVersionId,recipeVersionId: draft.recipeVersionId,
                canonicalAmount: draft.canonicalAmount,canonicalUnit: draft.canonicalUnit,db: db
            )
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: draft.localTimezone) ?? .current
            let boundary = try Int.fetchOne(
                db,sql: "SELECT nutrition_day_start_minutes FROM fitness_nutrition_settings WHERE deleted_at IS NULL LIMIT 1"
            ) ?? 240
            let date = FitnessCalculations.nutritionDate(
                for: draft.loggedAt,dayStartMinutes: boundary,calendar: calendar
            )
            let entry = FitnessFoodLogEntry(
                id: id,foodId: source.foodId,foodVersionId: draft.foodVersionId,
                foodName: draft.label,loggedAt: draft.loggedAt,nutritionDate: date,meal: draft.meal,
                amountGrams: draft.canonicalUnit == "g" ? draft.canonicalAmount : nil,
                kcal: source.nutrients.caloriesKcal,revision: baseRevision ?? 0,updatedAt: now,
                recipeVersionId: draft.recipeVersionId,localTimezone: draft.localTimezone,
                enteredAmount: draft.enteredAmount,enteredUnit: draft.enteredUnit,
                canonicalAmount: draft.canonicalAmount,canonicalUnit: draft.canonicalUnit,
                proteinG: source.nutrients.proteinG,carbohydrateG: source.nutrients.carbohydrateG,
                sugarsG: source.nutrients.sugarsG,fatG: source.nutrients.fatG,
                saturatedFatG: source.nutrients.saturatedFatG,fibreG: source.nutrients.fibreG,
                saltG: source.nutrients.saltG,sodiumMg: source.nutrients.sodiumMg,
                micronutrients: source.nutrients.micronutrients,
                measurementQuality: draft.measurementQuality,notes: trimmed(draft.notes),
                contextTags: draft.contextTags
            )
            try upsert(log: entry,db: db)
            try enqueue(
                db,type: .foodLogEntry,id: id,baseRevision: baseRevision,
                payload: FoodLogMutation(entry: entry),now: now
            )
            return entry
        }
    }

    func deleteLog(_ entry: FitnessFoodLogEntry) throws {
        let now = Date()
        try database.write { db in
            try db.execute(
                sql: "UPDATE fitness_food_log_entries SET deleted_at=?,client_updated_at=? WHERE id=?",
                arguments: [FitnessDatabase.dateString(now),FitnessDatabase.dateString(now),entry.id]
            )
            try enqueueDelete(
                db,type: .foodLogEntry,id: entry.id,baseRevision: entry.revision,now: now
            )
        }
    }

    @discardableResult
    func repeatEntries(
        _ sources: [FitnessFoodLogEntry],on targetDate: Date,meal: FitnessMeal? = nil
    ) throws -> [FitnessFoodLogEntry] {
        let selected = sources.filter { meal == nil || $0.meal == meal }
        guard !selected.isEmpty else { throw FitnessNutritionRepositoryError.invalidLog }
        let now = Date()
        return try database.write { db in
            let settingsRow = try Row.fetchOne(
                db,sql: "SELECT * FROM fitness_nutrition_settings WHERE deleted_at IS NULL LIMIT 1"
            )
            let timezone = currentTimeZone()
            let boundary: Int = settingsRow?["nutrition_day_start_minutes"] ?? 240
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timezone
            let targetDay = calendar.dateComponents([.year,.month,.day],from: targetDate)
            var output: [FitnessFoodLogEntry] = []
            for source in selected {
                var components = targetDay
                var sourceCalendar = calendar
                sourceCalendar.timeZone = TimeZone(identifier:source.localTimezone) ?? timezone
                let oldTime = sourceCalendar.dateComponents(
                    [.hour,.minute,.second],from: source.loggedAt
                )
                components.hour = oldTime.hour; components.minute = oldTime.minute; components.second = oldTime.second
                let loggedAt = calendar.date(from: components) ?? targetDate
                let id = UUID().uuidString
                var repeated = source
                repeated = FitnessFoodLogEntry(
                    id: id,foodId: source.foodId,foodVersionId: source.foodVersionId,
                    foodName: source.foodName,loggedAt: loggedAt,
                    nutritionDate: FitnessCalculations.nutritionDate(
                        for: loggedAt,dayStartMinutes: boundary,calendar: calendar
                    ),
                    meal: source.meal,amountGrams: source.amountGrams,kcal: source.kcal,
                    revision: 0,updatedAt: now,recipeVersionId: source.recipeVersionId,
                    localTimezone: timezone.identifier,enteredAmount: source.enteredAmount,
                    enteredUnit: source.enteredUnit,canonicalAmount: source.canonicalAmount,
                    canonicalUnit: source.canonicalUnit,proteinG: source.proteinG,
                    carbohydrateG: source.carbohydrateG,sugarsG: source.sugarsG,
                    fatG: source.fatG,saturatedFatG: source.saturatedFatG,
                    fibreG: source.fibreG,saltG: source.saltG,sodiumMg: source.sodiumMg,
                    micronutrients: source.micronutrients,measurementQuality: source.measurementQuality,
                    notes: source.notes,contextTags: source.contextTags
                )
                try upsert(log: repeated,db: db)
                try enqueue(
                    db,type: .foodLogEntry,id: id,baseRevision: nil,
                    payload: FoodLogMutation(entry: repeated),now: now
                )
                output.append(repeated)
            }
            return output
        }
    }

    // MARK: Recipes

    @discardableResult
    func createRecipe(_ draft: FitnessRecipeDraft) throws -> FitnessRecipe {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validRecipeDraft(draft,requiresName: true) else {
            throw FitnessNutritionRepositoryError.invalidRecipe
        }
        let now = Date()
        let recipeId = UUID().uuidString
        let versionId = UUID().uuidString
        return try database.write { db in
            let version = try makeRecipeVersion(
                id: versionId,recipeId: recipeId,versionNumber: 1,draft: draft,now: now,db: db
            )
            let recipe = FitnessRecipe(
                id: recipeId,name: name,notes: trimmed(draft.notes),
                householdShared: draft.householdShared,favourite: draft.favourite,active: true,
                editable: true,versions: [version],revision: 0,updatedAt: now,deletedAt: nil
            )
            try upsert(recipe: recipe,currentVersionId: versionId,db: db)
            try upsert(recipeVersion: version,db: db)
            try enqueue(
                db,type: .recipe,id: recipeId,baseRevision: nil,
                payload: RecipeMutation(
                    recipe: recipe,version: RecipeVersionMutation(version: version,includeRecipeId: false)
                ),now: now
            )
            return recipe
        }
    }

    @discardableResult
    func addRecipeVersion(recipeId: String,draft: FitnessRecipeDraft) throws -> FitnessRecipeVersion {
        guard validRecipeDraft(draft,requiresName: false) else {
            throw FitnessNutritionRepositoryError.invalidRecipe
        }
        let now = Date()
        return try database.write { db in
            guard try Bool.fetchOne(
                db,sql: "SELECT EXISTS(SELECT 1 FROM fitness_recipes WHERE id=? AND deleted_at IS NULL)",
                arguments: [recipeId]
            ) == true else { throw FitnessNutritionRepositoryError.missingRecord }
            let next = (try Int.fetchOne(
                db,sql: "SELECT COALESCE(MAX(version_number),0)+1 FROM fitness_recipe_versions WHERE recipe_id=?",
                arguments: [recipeId]
            )) ?? 1
            let version = try makeRecipeVersion(
                id: UUID().uuidString,recipeId: recipeId,versionNumber: next,draft: draft,now: now,db: db
            )
            try upsert(recipeVersion: version,db: db)
            try db.execute(
                sql: "UPDATE fitness_recipes SET current_version_id=?,client_updated_at=? WHERE id=?",
                arguments: [version.id,FitnessDatabase.dateString(now),recipeId]
            )
            try enqueue(
                db,type: .recipeVersion,id: version.id,baseRevision: nil,
                payload: RecipeVersionMutation(version: version,includeRecipeId: true),now: now
            )
            return version
        }
    }

    @discardableResult
    func saveRecipeIdentity(_ recipe: FitnessRecipe) throws -> FitnessRecipe {
        let now = Date()
        try database.write { db in
            try upsert(recipe: recipe,currentVersionId: recipe.currentVersion?.id,db: db)
            try enqueue(
                db,type: .recipe,id: recipe.id,baseRevision: recipe.revision,
                payload: RecipeMutation(recipe: recipe,version: nil),now: now
            )
        }
        return recipe
    }

    // MARK: Templates and targets

    @discardableResult
    func saveTemplate(_ template: FitnessMealTemplate,baseRevision: Int? = nil) throws -> FitnessMealTemplate {
        guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !template.items.isEmpty,template.items.allSatisfy({
                  $0.hasExactlyOneSource && $0.amount.isFinite && $0.amount > 0
                      && $0.canonicalAmount.isFinite && $0.canonicalAmount > 0
              }) else {
            throw FitnessNutritionRepositoryError.invalidTemplate
        }
        let now = Date()
        var value = template
        value.updatedAt = now
        try database.write { db in
            let foodIds=Array(Set(value.items.compactMap(\.foodVersionId))).sorted()
            let recipeIds=Array(Set(value.items.compactMap(\.recipeVersionId))).sorted()
            if !foodIds.isEmpty {
                let placeholders=Array(repeating:"?",count:foodIds.count).joined(separator:",")
                let existing=Set(try String.fetchAll(
                    db,sql:"SELECT id FROM fitness_food_versions WHERE id IN (\(placeholders)) AND deleted_at IS NULL",
                    arguments:StatementArguments(foodIds)
                ))
                guard existing == Set(foodIds) else { throw FitnessNutritionRepositoryError.missingRecord }
            }
            if !recipeIds.isEmpty {
                let placeholders=Array(repeating:"?",count:recipeIds.count).joined(separator:",")
                let existing=Set(try String.fetchAll(
                    db,sql:"SELECT id FROM fitness_recipe_versions WHERE id IN (\(placeholders)) AND deleted_at IS NULL",
                    arguments:StatementArguments(recipeIds)
                ))
                guard existing == Set(recipeIds) else { throw FitnessNutritionRepositoryError.missingRecord }
            }
            try upsert(template: value,db: db)
            try enqueue(
                db,type: .mealTemplate,id: value.id,baseRevision: baseRevision,
                payload: MealTemplateMutation(template: value),now: now
            )
        }
        return value
    }

    func archiveTemplate(_ template: FitnessMealTemplate) throws {
        var archived = template
        archived.active = false
        _ = try saveTemplate(archived,baseRevision: template.revision)
    }

    @discardableResult
    func logTemplate(
        _ template: FitnessMealTemplate,amounts: [String: Double],at loggedAt: Date,
        entryIds: [String: String] = [:]
    ) throws -> [FitnessFoodLogEntry] {
        guard !template.items.isEmpty else { throw FitnessNutritionRepositoryError.invalidTemplate }
        let timezone = currentTimeZone().identifier
        let now=Date()
        return try database.write { db in
            var calendar=Calendar(identifier: .gregorian)
            calendar.timeZone=TimeZone(identifier: timezone) ?? .current
            let boundary=try Int.fetchOne(
                db,sql: "SELECT nutrition_day_start_minutes FROM fitness_nutrition_settings WHERE deleted_at IS NULL LIMIT 1"
            ) ?? 240
            let nutritionDate=FitnessCalculations.nutritionDate(
                for: loggedAt,dayStartMinutes: boundary,calendar: calendar
            )
            let foodIds=Array(Set(template.items.compactMap(\.foodVersionId))).sorted()
            let recipeIds=Array(Set(template.items.compactMap(\.recipeVersionId))).sorted()
            var foodVersionsById: [String: FitnessFoodVersion]=[:]
            if !foodIds.isEmpty {
                let placeholders=Array(repeating:"?",count:foodIds.count).joined(separator:",")
                for row in try Row.fetchAll(
                    db,sql:"SELECT * FROM fitness_food_versions WHERE id IN (\(placeholders)) AND deleted_at IS NULL",
                    arguments:StatementArguments(foodIds)
                ) {
                    let version=try foodVersion(row)
                    foodVersionsById[version.id]=version
                }
            }
            var recipeVersionsById: [String: FitnessRecipeVersion]=[:]
            if !recipeIds.isEmpty {
                let placeholders=Array(repeating:"?",count:recipeIds.count).joined(separator:",")
                for row in try Row.fetchAll(
                    db,sql:"SELECT * FROM fitness_recipe_versions WHERE id IN (\(placeholders)) AND deleted_at IS NULL",
                    arguments:StatementArguments(recipeIds)
                ) {
                    let version=try recipeVersion(row)
                    recipeVersionsById[version.id]=version
                }
            }
            var created: [FitnessFoodLogEntry]=[]
            // All separate records and all outbox rows share one GRDB transaction.
            for item in template.items.sorted(by: { $0.sequence < $1.sequence }) {
                let amount=amounts[item.id] ?? item.amount
                guard amount.isFinite,amount > 0,item.amount.isFinite,item.amount > 0 else {
                    throw FitnessNutritionRepositoryError.invalidTemplate
                }
                let canonical=item.canonicalAmount*(amount/item.amount)
                let source=try sourceSnapshot(
                    foodVersion: item.foodVersionId.flatMap { foodVersionsById[$0] },
                    recipeVersion: item.recipeVersionId.flatMap { recipeVersionsById[$0] },
                    canonicalAmount: canonical,canonicalUnit: item.canonicalUnit
                )
                let entry=FitnessFoodLogEntry(
                    id: entryIds[item.id] ?? UUID().uuidString,
                    foodId: source.foodId,foodVersionId: item.foodVersionId,
                    foodName: item.label ?? "Saved item",loggedAt: loggedAt,nutritionDate: nutritionDate,
                    meal: template.meal,amountGrams: item.canonicalUnit == "g" ? canonical : nil,
                    kcal: source.nutrients.caloriesKcal,revision: 0,updatedAt: now,
                    recipeVersionId: item.recipeVersionId,localTimezone: timezone,
                    enteredAmount: amount,enteredUnit: item.unit,canonicalAmount: canonical,
                    canonicalUnit: item.canonicalUnit,proteinG: source.nutrients.proteinG,
                    carbohydrateG: source.nutrients.carbohydrateG,sugarsG: source.nutrients.sugarsG,
                    fatG: source.nutrients.fatG,saturatedFatG: source.nutrients.saturatedFatG,
                    fibreG: source.nutrients.fibreG,saltG: source.nutrients.saltG,
                    sodiumMg: source.nutrients.sodiumMg,micronutrients: source.nutrients.micronutrients,
                    measurementQuality: item.measurementQuality,notes: nil,contextTags: []
                )
                try upsert(log: entry,db: db)
                try enqueue(
                    db,type: .foodLogEntry,id: entry.id,baseRevision: nil,
                    payload: FoodLogMutation(entry: entry),now: now
                )
                created.append(entry)
            }
            return created
        }
    }

    @discardableResult
    func saveTarget(_ target: FitnessNutritionTarget,baseRevision: Int? = nil) throws -> FitnessNutritionTarget {
        guard target.isValid else { throw FitnessNutritionRepositoryError.invalidTarget }
        let now = Date()
        var value = target
        value.updatedAt = now
        try database.write { db in
            try upsert(target: value,db: db)
            try enqueue(
                db,type: .nutritionTarget,id: value.id,baseRevision: baseRevision,
                payload: NutritionTargetMutation(target: value),now: now
            )
        }
        return value
    }

    func archiveTarget(_ target: FitnessNutritionTarget) throws {
        var archived = target
        archived.active = false
        _ = try saveTarget(archived,baseRevision: target.revision)
    }

    // MARK: Private nutrition labels

    /// Reclaims only stale label files that have no row in the active owner's
    /// private-upload table. Any corrupt reference, unexpected filename, fresh
    /// write, directory, or symlink fails closed outside the deletion set.
    @discardableResult
    func reconcilePrivateLabelFiles(
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        maximumCandidates: Int = 256,
        maximumRemovals: Int = 32
    ) throws -> Int {
        guard maximumCandidates > 0, maximumRemovals > 0 else { return 0 }
        guard let profileRoot = database.activeStoreURL?
            .deletingLastPathComponent().standardizedFileURL else {
            throw FitnessDatabaseError.notActive
        }
        let directory = profileRoot
            .appendingPathComponent("PrivateRequired/NutritionLabels",isDirectory: true)
            .standardizedFileURL
        try LocalFileProtection.prepareDirectory(directory,fileManager: fileManager)
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw FitnessNutritionRepositoryError.unsafePath
        }
        let relativePaths = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT relative_path FROM fitness_private_file_uploads WHERE asset_kind='nutrition_label'"
            )
        }
        var referenced = Set<String>()
        for relativePath in relativePaths {
            let url = profileRoot.appendingPathComponent(relativePath).standardizedFileURL
            guard url.deletingLastPathComponent() == directory,
                  Self.isOwnedNutritionLabelFilename(url.lastPathComponent) else {
                throw FitnessNutritionRepositoryError.unsafePath
            }
            referenced.insert(url.lastPathComponent)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        guard let entries = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
        ) else {
            throw FitnessNutritionRepositoryError.unsafePath
        }
        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        var candidates = 0
        var removed = 0
        while let nextEntry = entries.nextObject() {
            try Task.checkCancellation()
            guard candidates < maximumCandidates,removed < maximumRemovals else { break }
            guard let entry = nextEntry as? URL else { continue }
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  !referenced.contains(candidate.lastPathComponent),
                  try Self.isReclaimableNutritionLabelCandidate(
                      candidate,
                      directory: directory,
                      referenced: referenced,
                      keys: keys,
                      cutoff: cutoff
                  ) else { continue }
            candidates += 1
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                fitnessNutritionRepositoryLogger.error(
                    "Nutrition-label reconciliation could not remove an owned orphan; a later reconciliation will retry: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
        }
        return removed
    }

    func localLabelURL(assetId: String) throws -> URL {
        guard let profileRoot = database.activeStoreURL?
            .deletingLastPathComponent().standardizedFileURL else {
            throw FitnessDatabaseError.notActive
        }
        let labelDirectory = profileRoot
            .appendingPathComponent("PrivateRequired/NutritionLabels",isDirectory: true)
            .standardizedFileURL
        return try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT relative_path,media_type,byte_count FROM fitness_private_file_uploads WHERE asset_id=? AND asset_kind='nutrition_label'",
                arguments: [assetId]
            ) else { throw FitnessNutritionRepositoryError.missingRecord }
            let relative: String = row["relative_path"]
            let expectedMediaType: String = row["media_type"]
            let expectedByteCount: Int = row["byte_count"]
            let url = try privateLabelURL(relativePath: relative)
            let stagedFile = PhotoUploadPrep.StagedFile(
                directoryURL: labelDirectory,
                fileURL: url
            )
            guard url.deletingLastPathComponent() == labelDirectory,
                  Self.isOwnedNutritionLabelFilename(url.lastPathComponent) else {
                throw FitnessNutritionRepositoryError.missingRecord
            }
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount > 0,
                  byteCount <= FitnessNutritionLabelDraft.maximumByteCount,
                  byteCount == expectedByteCount,
                  try PhotoUploadPrep.validatedStagedImageByteCount(
                    stagedFile,
                    declaredTypeIdentifiers: []
                  ) == expectedByteCount,
                  PhotoUploadPrep.fileMetadata(at: url)?.mediaType
                    == expectedMediaType.lowercased() else {
                throw FitnessNutritionRepositoryError.missingRecord
            }
            return url
        }
    }

    func markLabelUploadAcknowledged(assetId: String,result: FitnessPrivateAssetUploadResult) throws {
        guard result.assetId == assetId,result.uploadAcknowledged,result.state == "staged",
              result.storageClass == "private_required" else {
            throw FitnessNutritionRepositoryError.invalidLabel
        }
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads
                       SET upload_acknowledged=1,state='uploaded_waiting_reference',
                           last_attempt_at=?,attempt_count=attempt_count+1,last_error=NULL
                     WHERE asset_id=? AND asset_kind='nutrition_label'
                    """,
                arguments: [FitnessDatabase.dateString(Date()),assetId]
            )
        }
    }

    func markLabelFailure(assetId: String,message: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads
                       SET state='error',last_attempt_at=?,attempt_count=attempt_count+1,last_error=?
                     WHERE asset_id=? AND asset_kind='nutrition_label'
                    """,
                arguments: [FitnessDatabase.dateString(Date()),String(message.prefix(1_000)),assetId]
            )
        }
    }

    func retryLabel(assetId: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads
                       SET state=CASE WHEN upload_acknowledged=1 THEN 'uploaded_waiting_reference'
                                      ELSE 'pending_upload' END,last_error=NULL
                     WHERE asset_id=? AND asset_kind='nutrition_label'
                    """,
                arguments: [assetId]
            )
        }
    }

    func removePendingLabel(assetId: String) throws {
        var url: URL?
        try database.write { db in
            guard let row = try Row.fetchOne(
                db,sql: "SELECT * FROM fitness_private_file_uploads WHERE asset_id=? AND asset_kind='nutrition_label'",
                arguments: [assetId]
            ) else { return }
            guard (row["upload_acknowledged"] as Int) == 0 else {
                throw FitnessNutritionRepositoryError.invalidLabel
            }
            url = try privateLabelURL(relativePath: row["relative_path"])
            if let mutationId: String = row["dependent_mutation_id"] {
                try db.execute(sql: "DELETE FROM fitness_outbox WHERE mutation_id=?",arguments: [mutationId])
            }
            try db.execute(sql: "DELETE FROM fitness_private_file_uploads WHERE asset_id=?",arguments: [assetId])
        }
        if let url,fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    func finalizeAbandonedLabel(assetId: String) throws {
        var url: URL?
        try database.write { db in
            guard let row = try Row.fetchOne(
                db,sql: "SELECT * FROM fitness_private_file_uploads WHERE asset_id=? AND asset_kind='nutrition_label'",
                arguments: [assetId]
            ) else { return }
            url = try privateLabelURL(relativePath: row["relative_path"])
            if let mutationId: String = row["dependent_mutation_id"] {
                try db.execute(sql: "DELETE FROM fitness_outbox WHERE mutation_id=?",arguments: [mutationId])
            }
            try db.execute(sql: "DELETE FROM fitness_private_file_uploads WHERE asset_id=?",arguments: [assetId])
        }
        if let url,fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    func cleanupAcknowledgedLabels() throws {
        let rows: [(String,String)] = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT asset_id,relative_path FROM fitness_private_file_uploads
                    WHERE asset_kind='nutrition_label' AND upload_acknowledged=1 AND metadata_acknowledged=1
                    """
            ).map { ($0["asset_id"],$0["relative_path"]) }
        }
        for (_,relative) in rows {
            let url = try privateLabelURL(relativePath: relative)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        try database.write { db in
            for (id,_) in rows {
                try db.execute(
                    sql: """
                        DELETE FROM fitness_private_file_uploads WHERE asset_id=?
                          AND upload_acknowledged=1 AND metadata_acknowledged=1
                        """,
                    arguments: [id]
                )
            }
        }
    }

    func applyRebucketResult(minutes: Int,timezone: String) throws {
        let safe = min(max(minutes,0),480)
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            let id = try String.fetchOne(
                db,sql: "SELECT id FROM fitness_nutrition_settings WHERE deleted_at IS NULL LIMIT 1"
            ) ?? "nutrition-settings"
            try db.execute(
                sql: """
                    INSERT INTO fitness_nutrition_settings
                    (id,day_boundary_hour,revision,client_updated_at,origin_device_id,timezone,nutrition_day_start_minutes)
                    VALUES (?,?,0,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET timezone=excluded.timezone,
                      nutrition_day_start_minutes=excluded.nutrition_day_start_minutes,
                      day_boundary_hour=excluded.day_boundary_hour,client_updated_at=excluded.client_updated_at
                    """,
                arguments: [id,safe/60,now,try deviceId,timezone,safe]
            )
            // The server response is authoritative after a rebucket. Recompute the
            // local cache immediately so offline grouping matches before the next pull.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timezone) ?? .current
            let logs = try Row.fetchAll(
                db,sql: "SELECT id,logged_at,local_timezone FROM fitness_food_log_entries WHERE deleted_at IS NULL"
            )
            for row in logs {
                guard let logged = FitnessDatabase.date(row["logged_at"]) else { continue }
                var entryCalendar = Calendar(identifier: .gregorian)
                let entryTimezone: String? = row["local_timezone"]
                entryCalendar.timeZone = entryTimezone.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
                try db.execute(
                    sql: "UPDATE fitness_food_log_entries SET nutrition_date=? WHERE id=?",
                    arguments: [FitnessCalculations.nutritionDate(for: logged,dayStartMinutes: safe,calendar: entryCalendar),row["id"]]
                )
            }
        }
    }

    func applySettings(_ settings: FitnessNutritionSettings) throws {
        let now = FitnessDatabase.dateString(Date())
        let zones = try settings.heartRateZoneBoundariesBpm.map { values in
            try String(
                decoding: JSONSerialization.data(withJSONObject: values,options: [.sortedKeys]),
                as: UTF8.self
            )
        }
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_nutrition_settings
                    (id,day_boundary_hour,revision,server_updated_at,client_updated_at,
                     origin_device_id,timezone,nutrition_day_start_minutes,
                     heart_rate_zone_boundaries_json)
                    VALUES (?,?,?,?,?,'server',?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      day_boundary_hour=excluded.day_boundary_hour,
                      revision=excluded.revision,
                      server_updated_at=excluded.server_updated_at,
                      client_updated_at=excluded.client_updated_at,
                      timezone=excluded.timezone,
                      nutrition_day_start_minutes=excluded.nutrition_day_start_minutes,
                      heart_rate_zone_boundaries_json=excluded.heart_rate_zone_boundaries_json
                    """,
                arguments: [
                    settings.id,settings.nutritionDayStartMinutes/60,settings.revision,
                    now,now,settings.timezone,settings.nutritionDayStartMinutes,zones,
                ]
            )
        }
    }

    // MARK: Mapping

    private func foods(rows: [Row],db: Database) throws -> [FitnessFood] {
        guard !rows.isEmpty else { return [] }
        let foodIds: [String] = rows.map { $0["id"] }
        let placeholders = Array(repeating: "?",count: foodIds.count).joined(separator: ",")
        let arguments = StatementArguments(foodIds)

        let versionRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM fitness_food_versions
                WHERE food_id IN (\(placeholders)) AND deleted_at IS NULL
                ORDER BY food_id,version_number DESC,created_at DESC
                """,
            arguments: arguments
        )
        var versionsByFood: [String: [FitnessFoodVersion]] = [:]
        for versionRow in versionRows {
            let version = try foodVersion(versionRow)
            versionsByFood[version.foodId,default: []].append(version)
        }

        let servingRows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM fitness_food_servings
                WHERE food_id IN (\(placeholders)) AND deleted_at IS NULL
                ORDER BY food_id,is_default DESC,name
                """,
            arguments: arguments
        )
        var servingsByFood: [String: [FitnessFoodServing]] = [:]
        for servingRow in servingRows {
            let serving = foodServing(servingRow)
            servingsByFood[serving.foodId,default: []].append(serving)
        }

        let recentMealRows = try Row.fetchAll(
            db,
            sql: """
                WITH meal_recency AS (
                    SELECT v.food_id,l.meal_key,MAX(l.logged_at) AS latest_at
                    FROM fitness_food_log_entries l
                    JOIN fitness_food_versions v ON v.id=l.food_version_id
                    WHERE v.food_id IN (\(placeholders)) AND l.deleted_at IS NULL
                    GROUP BY v.food_id,l.meal_key
                ), ranked AS (
                    SELECT food_id,meal_key,
                           ROW_NUMBER() OVER (
                               PARTITION BY food_id ORDER BY latest_at DESC,meal_key
                           ) AS meal_rank
                    FROM meal_recency
                )
                SELECT food_id,meal_key FROM ranked WHERE meal_rank<=4
                ORDER BY food_id,meal_rank
                """,
            arguments: arguments
        )
        var recentMealsByFood: [String: [FitnessMeal]] = [:]
        for mealRow in recentMealRows {
            let foodId: String = mealRow["food_id"]
            guard let meal = FitnessMeal(rawValue: mealRow["meal_key"]) else { continue }
            recentMealsByFood[foodId,default: []].append(meal)
        }

        let quickRows = try Row.fetchAll(
            db,
            sql: """
                WITH ranked AS (
                    SELECT v.food_id,l.entered_amount,l.entered_unit,l.logged_at,
                           COUNT(*) OVER (PARTITION BY v.food_id) AS frequency_count,
                           ROW_NUMBER() OVER (
                               PARTITION BY v.food_id ORDER BY l.logged_at DESC,l.id DESC
                           ) AS log_rank
                    FROM fitness_food_log_entries l
                    JOIN fitness_food_versions v ON v.id=l.food_version_id
                    WHERE v.food_id IN (\(placeholders)) AND l.deleted_at IS NULL
                )
                SELECT * FROM ranked WHERE log_rank=1
                """,
            arguments: arguments
        )
        var quickUseByFood: [String: FitnessFoodQuickUse] = [:]
        for quickRow in quickRows {
            let foodId: String = quickRow["food_id"]
            let amount: Double? = quickRow["entered_amount"]
            let unit: String? = quickRow["entered_unit"]
            let count: Int = quickRow["frequency_count"]
            quickUseByFood[foodId] = FitnessFoodQuickUse(
                lastLoggedAtUtc: FitnessDatabase.date(quickRow["logged_at"]),
                lastAmount: amount,lastUnit: unit,
                usualAmount: count > 1 ? amount : nil,usualUnit: count > 1 ? unit : nil,
                frequencyCount: count,recentMealKeys: recentMealsByFood[foodId] ?? []
            )
        }

        return rows.map { row in
            let id: String = row["id"]
            return food(
                row: row,versions: versionsByFood[id] ?? [],
                servings: servingsByFood[id] ?? [],quickUse: quickUseByFood[id]
            )
        }
    }

    private static func integerArray(_ value: String?) throws -> [Int]? {
        guard let value else { return nil }
        return try JSONDecoder().decode([Int].self,from: Data(value.utf8))
    }

    private func food(row: Row,db: Database) throws -> FitnessFood {
        let id: String = row["id"]
        let versions = try Row.fetchAll(
            db,
            sql: "SELECT * FROM fitness_food_versions WHERE food_id=? AND deleted_at IS NULL ORDER BY version_number DESC,created_at DESC",
            arguments: [id]
        ).map { try foodVersion($0) }
        let servings = try Row.fetchAll(
            db,
            sql: "SELECT * FROM fitness_food_servings WHERE food_id=? AND deleted_at IS NULL ORDER BY is_default DESC,name",
            arguments: [id]
        ).map(foodServing)
        let latestLog = try Row.fetchOne(
            db,
            sql: """
                SELECT l.entered_amount,l.entered_unit,l.logged_at,l.meal_key
                FROM fitness_food_log_entries l JOIN fitness_food_versions v ON v.id=l.food_version_id
                WHERE v.food_id=? AND l.deleted_at IS NULL ORDER BY l.logged_at DESC LIMIT 1
                """,
            arguments: [id]
        )
        let count = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM fitness_food_log_entries l
                JOIN fitness_food_versions v ON v.id=l.food_version_id
                WHERE v.food_id=? AND l.deleted_at IS NULL
                """,
            arguments: [id]
        ) ?? 0
        let recentMeals = try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT l.meal_key FROM fitness_food_log_entries l
                JOIN fitness_food_versions v ON v.id=l.food_version_id
                WHERE v.food_id=? AND l.deleted_at IS NULL ORDER BY l.logged_at DESC LIMIT 4
                """,
            arguments: [id]
        ).compactMap(FitnessMeal.init(rawValue:))
        let quick = latestLog.map {
            let amount: Double? = $0["entered_amount"]
            let unit: String? = $0["entered_unit"]
            return FitnessFoodQuickUse(
                lastLoggedAtUtc: FitnessDatabase.date($0["logged_at"]),lastAmount: amount,
                lastUnit: unit,usualAmount: count > 1 ? amount : nil,usualUnit: count > 1 ? unit : nil,
                frequencyCount: count,recentMealKeys: recentMeals
            )
        }
        return food(row: row,versions: versions,servings: servings,quickUse: quick)
    }

    private func food(
        row: Row,versions: [FitnessFoodVersion],servings: [FitnessFoodServing],
        quickUse: FitnessFoodQuickUse?
    ) -> FitnessFood {
        let id: String = row["id"]
        let currentId: String = row["current_version_id"]
        let current = versions.first { $0.id == currentId }
        return FitnessFood(
            id: id,versionId: currentId,name: row["name"],brand: row["brand"],
            kcalPer100g: current.flatMap(per100Calories),
            defaultServingGrams: servings.first { $0.isDefault && $0.canonicalUnit == "g" }?.canonicalAmount,
            isFavourite: (row["is_favourite"] as Int) != 0,
            isArchived: (row["active"] as Int) == 0,revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            categoryKey: row["category_key"],barcode: row["barcode"],notes: row["notes"],
            householdShared: (row["household_shared"] as Int) != 0,
            active: (row["active"] as Int) != 0,mergedIntoFoodId: row["merged_into_food_id"],
            editable: (row["editable"] as Int) != 0,versions: versions,servings: servings,quickUse: quickUse
        )
    }

    private func foodVersion(_ row: Row) throws -> FitnessFoodVersion {
        try FitnessFoodVersion(
            id: row["id"],foodId: row["food_id"],versionNumber: row["version_number"],
            effectiveFrom: row["effective_from"],referenceAmount: row["reference_amount"],
            referenceUnit: row["reference_unit"],caloriesKcal: row["calories_kcal"],
            sourceEnergyValue: row["source_energy_value"],sourceEnergyUnit: row["source_energy_unit"],
            proteinG: row["protein_g"],carbohydrateG: row["carbohydrate_g"],
            sugarsG: row["sugars_g"],fatG: row["fat_g"],saturatedFatG: row["saturated_fat_g"],
            fibreG: row["fibre_g"],saltG: row["salt_g"],sodiumMg: row["sodium_mg"],
            micronutrients: decode([String: Double?].self,row["micronutrients_json"]) ?? [:],
            sourceType: row["source_type"],sourceNote: row["source_note"],confidence: row["confidence"],
            labelAssetId: row["label_asset_id"],revision: row["revision"],
            createdAt: FitnessDatabase.date(row["created_at"]) ?? .distantPast,
            updatedAt: FitnessDatabase.date(row["client_updated_at"] ?? row["created_at"]) ?? .distantPast,
            deletedAt: FitnessDatabase.date(row["deleted_at"])
        )
    }

    private func foodServing(_ row: Row) -> FitnessFoodServing {
        FitnessFoodServing(
            id: row["id"],foodId: row["food_id"],name: row["name"],amount: row["amount"],unit: row["unit"],
            canonicalAmount: row["canonical_amount"],canonicalUnit: row["canonical_unit"],
            measurementQuality: FitnessNutritionMeasurementQuality(rawValue: row["measurement_quality"]) ?? .estimated,
            isDefault: (row["is_default"] as Int) != 0,active: (row["active"] as Int) != 0,
            revision: row["revision"],updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            deletedAt: FitnessDatabase.date(row["deleted_at"])
        )
    }

    private func recipe(row: Row,db: Database) throws -> FitnessRecipe {
        let id: String = row["id"]
        let versions = try Row.fetchAll(
            db,
            sql: "SELECT * FROM fitness_recipe_versions WHERE recipe_id=? AND deleted_at IS NULL ORDER BY version_number DESC",
            arguments: [id]
        ).map { try recipeVersion($0) }
        return recipe(row: row,versions: versions)
    }

    private func recipe(row: Row,versions: [FitnessRecipeVersion]) -> FitnessRecipe {
        let id: String = row["id"]
        return FitnessRecipe(
            id: id,name: row["name"],notes: row["notes"],
            householdShared: (row["household_shared"] as Int) != 0,
            favourite: (row["favourite"] as Int) != 0,active: (row["active"] as Int) != 0,
            editable: (row["editable"] as Int) != 0,
            versions: versions,revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            deletedAt: FitnessDatabase.date(row["deleted_at"])
        )
    }

    private func recipeVersion(_ row: Row) throws -> FitnessRecipeVersion {
        let nutrients = FitnessNutritionValues(
            caloriesKcal: row["calories_kcal"],proteinG: row["protein_g"],
            carbohydrateG: row["carbohydrate_g"],sugarsG: row["sugars_g"],fatG: row["fat_g"],
            saturatedFatG: row["saturated_fat_g"],fibreG: row["fibre_g"],saltG: row["salt_g"]
        )
        return try FitnessRecipeVersion(
            id: row["id"],recipeId: row["recipe_id"],versionNumber: row["version_number"],
            components: decode([FitnessRecipeComponent].self,row["components_json"]) ?? [],
            finishedWeightG: row["finished_weight_g"],servings: row["servings"],nutrients: nutrients,
            per100G: decode(FitnessNutritionValues.self,row["per_100_g_json"]),
            lowerCaloriesKcal: row["lower_calories_kcal"],upperCaloriesKcal: row["upper_calories_kcal"],
            confidence: row["confidence"],sourceNote: row["source_note"],revision: row["revision"],
            createdAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            deletedAt: FitnessDatabase.date(row["deleted_at"])
        )
    }

    private func template(_ row: Row) throws -> FitnessMealTemplate {
        try FitnessMealTemplate(
            id: row["id"],name: row["name"],meal: FitnessMeal(rawValue: row["meal_key"]) ?? .other,
            timeRelevance: row["time_relevance"],favourite: (row["favourite"] as Int) != 0,
            active: (row["active"] as Int) != 0,
            items: decode([FitnessMealTemplateItem].self,row["items_json"]) ?? [],
            revision: row["revision"],updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            deletedAt: FitnessDatabase.date(row["deleted_at"])
        )
    }

    private func target(_ row: Row) -> FitnessNutritionTarget? {
        guard let metric = FitnessNutritionMetric(rawValue: row["metric_key"]),
              let mode = FitnessNutritionTargetMode(rawValue: row["target_type"]) else { return nil }
        return FitnessNutritionTarget(
            id: row["id"],metric: metric,mode: mode,targetValue: row["target_value"],
            targetMin: row["target_min"],targetMax: row["target_max"],
            trainingDayValue: row["training_day_value"],restDayValue: row["rest_day_value"],
            phaseId: row["phase_id"],effectiveFrom: row["effective_from"],effectiveUntil: row["effective_until"],
            active: (row["active"] as Int) != 0,revision: row["revision"],
            updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            deletedAt: FitnessDatabase.date(row["deleted_at"])
        )
    }

    private func logEntry(_ row: Row) throws -> FitnessFoodLogEntry {
        let canonical: Double = row["canonical_amount"] ?? row["amount_grams"] ?? 1
        let entered: Double = row["entered_amount"] ?? row["amount_grams"] ?? canonical
        let mealKey: String = row["meal_key"] ?? row["meal"] ?? "other"
        return try FitnessFoodLogEntry(
            id: row["id"],foodId: row["food_id"],foodVersionId: row["food_version_id"],
            foodName: row["food_name"],loggedAt: FitnessDatabase.date(row["logged_at"]) ?? .distantPast,
            nutritionDate: row["nutrition_date"],meal: FitnessMeal(rawValue: mealKey) ?? .other,
            amountGrams: row["amount_grams"],kcal: row["calories_kcal"] ?? row["kcal"],
            revision: row["revision"],updatedAt: FitnessDatabase.date(row["client_updated_at"]) ?? .distantPast,
            recipeVersionId: row["recipe_version_id"],localTimezone: row["local_timezone"] ?? "UTC",
            enteredAmount: entered,enteredUnit: row["entered_unit"] ?? "g",
            canonicalAmount: canonical,canonicalUnit: row["canonical_unit"] ?? "g",
            proteinG: row["protein_g"],carbohydrateG: row["carbohydrate_g"],sugarsG: row["sugars_g"],
            fatG: row["fat_g"],saturatedFatG: row["saturated_fat_g"],fibreG: row["fibre_g"],
            saltG: row["salt_g"],sodiumMg: row["sodium_mg"],
            micronutrients: decode([String: Double?].self,row["micronutrients_json"]) ?? [:],
            measurementQuality: FitnessNutritionMeasurementQuality(rawValue: row["measurement_quality"]) ?? .estimated,
            notes: row["notes"],contextTags: decode([String].self,row["context_tags_json"]) ?? []
        )
    }

    // MARK: Storage

    private func upsert(food: FitnessFood,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_foods
                (id,current_version_id,name,brand,is_favourite,is_archived,revision,client_updated_at,
                 origin_device_id,category_key,barcode,notes,household_shared,active,
                 merged_into_food_id,editable,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  current_version_id=excluded.current_version_id,name=excluded.name,brand=excluded.brand,
                  is_favourite=excluded.is_favourite,is_archived=excluded.is_archived,
                  category_key=excluded.category_key,barcode=excluded.barcode,notes=excluded.notes,
                  household_shared=excluded.household_shared,active=excluded.active,
                  merged_into_food_id=excluded.merged_into_food_id,editable=excluded.editable,
                  revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                food.id,food.versionId,food.name,food.brand,food.isFavourite,food.isArchived,
                food.revision,FitnessDatabase.dateString(food.updatedAt),try deviceId,food.categoryKey,
                food.barcode,food.notes,food.householdShared,food.active,food.mergedIntoFoodId,
                food.editable,try json(food),
            ]
        )
    }

    private func upsert(version: FitnessFoodVersion,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_food_versions
                (id,food_id,kcal_per_100g,default_serving_grams,created_at,superseded_at,
                 version_number,effective_from,reference_amount,reference_unit,calories_kcal,
                 source_energy_value,source_energy_unit,protein_g,carbohydrate_g,sugars_g,fat_g,
                 saturated_fat_g,fibre_g,salt_g,sodium_mg,micronutrients_json,source_type,
                 source_note,confidence,label_asset_id,revision,client_updated_at,origin_device_id,
                 deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  food_id=excluded.food_id,version_number=excluded.version_number,
                  effective_from=excluded.effective_from,reference_amount=excluded.reference_amount,
                  reference_unit=excluded.reference_unit,calories_kcal=excluded.calories_kcal,
                  kcal_per_100g=excluded.kcal_per_100g,source_energy_value=excluded.source_energy_value,
                  source_energy_unit=excluded.source_energy_unit,protein_g=excluded.protein_g,
                  carbohydrate_g=excluded.carbohydrate_g,sugars_g=excluded.sugars_g,
                  fat_g=excluded.fat_g,saturated_fat_g=excluded.saturated_fat_g,
                  fibre_g=excluded.fibre_g,salt_g=excluded.salt_g,sodium_mg=excluded.sodium_mg,
                  micronutrients_json=excluded.micronutrients_json,source_type=excluded.source_type,
                  source_note=excluded.source_note,confidence=excluded.confidence,
                  label_asset_id=excluded.label_asset_id,revision=excluded.revision,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                version.id,version.foodId,per100Calories(version),nil,
                FitnessDatabase.dateString(version.createdAt),nil,version.versionNumber,
                version.effectiveFrom,version.referenceAmount,version.referenceUnit,
                version.caloriesKcal,version.sourceEnergyValue,version.sourceEnergyUnit,
                version.proteinG,version.carbohydrateG,version.sugarsG,version.fatG,
                version.saturatedFatG,version.fibreG,version.saltG,version.sodiumMg,
                try json(version.micronutrients),version.sourceType,version.sourceNote,
                version.confidence,version.labelAssetId,version.revision,
                FitnessDatabase.dateString(version.updatedAt),try deviceId,
                version.deletedAt.map(FitnessDatabase.dateString),try json(version),
            ]
        )
    }

    private func upsert(serving: FitnessFoodServing,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_food_servings
                (id,food_id,name,amount,unit,canonical_amount,canonical_unit,measurement_quality,
                 is_default,active,revision,client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET food_id=excluded.food_id,name=excluded.name,
                  amount=excluded.amount,unit=excluded.unit,canonical_amount=excluded.canonical_amount,
                  canonical_unit=excluded.canonical_unit,measurement_quality=excluded.measurement_quality,
                  is_default=excluded.is_default,active=excluded.active,revision=excluded.revision,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                serving.id,serving.foodId,serving.name,serving.amount,serving.unit,
                serving.canonicalAmount,serving.canonicalUnit,serving.measurementQuality.rawValue,
                serving.isDefault,serving.active,serving.revision,FitnessDatabase.dateString(serving.updatedAt),
                try deviceId,serving.deletedAt.map(FitnessDatabase.dateString),try json(serving),
            ]
        )
    }

    private func upsert(log: FitnessFoodLogEntry,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_food_log_entries
                (id,food_id,food_version_id,food_name,logged_at,nutrition_date,meal,amount_grams,kcal,
                 revision,client_updated_at,origin_device_id,recipe_version_id,local_timezone,meal_key,
                 entered_amount,entered_unit,canonical_amount,canonical_unit,calories_kcal,protein_g,
                 carbohydrate_g,sugars_g,fat_g,saturated_fat_g,fibre_g,salt_g,sodium_mg,
                 micronutrients_json,measurement_quality,notes,context_tags_json,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET food_id=excluded.food_id,
                  food_version_id=excluded.food_version_id,recipe_version_id=excluded.recipe_version_id,
                  food_name=excluded.food_name,logged_at=excluded.logged_at,
                  nutrition_date=excluded.nutrition_date,meal=excluded.meal,meal_key=excluded.meal_key,
                  amount_grams=excluded.amount_grams,kcal=excluded.kcal,
                  local_timezone=excluded.local_timezone,entered_amount=excluded.entered_amount,
                  entered_unit=excluded.entered_unit,canonical_amount=excluded.canonical_amount,
                  canonical_unit=excluded.canonical_unit,calories_kcal=excluded.calories_kcal,
                  protein_g=excluded.protein_g,carbohydrate_g=excluded.carbohydrate_g,
                  sugars_g=excluded.sugars_g,fat_g=excluded.fat_g,
                  saturated_fat_g=excluded.saturated_fat_g,fibre_g=excluded.fibre_g,
                  salt_g=excluded.salt_g,sodium_mg=excluded.sodium_mg,
                  micronutrients_json=excluded.micronutrients_json,
                  measurement_quality=excluded.measurement_quality,notes=excluded.notes,
                  context_tags_json=excluded.context_tags_json,revision=excluded.revision,
                  client_updated_at=excluded.client_updated_at,deleted_at=NULL,payload_json=excluded.payload_json
                """,
            arguments: [
                log.id,log.foodId,log.foodVersionId,log.foodName,FitnessDatabase.dateString(log.loggedAt),
                log.nutritionDate,log.meal.rawValue,log.amountGrams,log.kcal,log.revision,
                FitnessDatabase.dateString(log.updatedAt),try deviceId,log.recipeVersionId,log.localTimezone,
                log.meal.rawValue,log.enteredAmount,log.enteredUnit,log.canonicalAmount,
                log.canonicalUnit,log.kcal,log.proteinG,log.carbohydrateG,log.sugarsG,
                log.fatG,log.saturatedFatG,log.fibreG,log.saltG,log.sodiumMg,
                try json(log.micronutrients),log.measurementQuality.rawValue,log.notes,
                try json(log.contextTags),try json(log),
            ]
        )
    }

    private func upsert(recipe: FitnessRecipe,currentVersionId: String?,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_recipes
                (id,current_version_id,name,notes,household_shared,favourite,active,editable,revision,
                 client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET current_version_id=COALESCE(excluded.current_version_id,fitness_recipes.current_version_id),
                  name=excluded.name,notes=excluded.notes,household_shared=excluded.household_shared,
                  favourite=excluded.favourite,active=excluded.active,editable=excluded.editable,
                  revision=excluded.revision,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                recipe.id,currentVersionId,recipe.name,recipe.notes,recipe.householdShared,
                recipe.favourite,recipe.active,recipe.editable,recipe.revision,FitnessDatabase.dateString(recipe.updatedAt),
                try deviceId,recipe.deletedAt.map(FitnessDatabase.dateString),try json(recipe),
            ]
        )
    }

    private func upsert(recipeVersion: FitnessRecipeVersion,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_recipe_versions
                (id,recipe_id,version_number,finished_weight_g,servings,calories_kcal,protein_g,
                 carbohydrate_g,sugars_g,fat_g,saturated_fat_g,fibre_g,salt_g,
                 lower_calories_kcal,upper_calories_kcal,confidence,source_note,components_json,
                 per_100_g_json,revision,client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET recipe_id=excluded.recipe_id,
                  version_number=excluded.version_number,finished_weight_g=excluded.finished_weight_g,
                  servings=excluded.servings,calories_kcal=excluded.calories_kcal,
                  protein_g=excluded.protein_g,carbohydrate_g=excluded.carbohydrate_g,
                  sugars_g=excluded.sugars_g,fat_g=excluded.fat_g,
                  saturated_fat_g=excluded.saturated_fat_g,fibre_g=excluded.fibre_g,
                  salt_g=excluded.salt_g,lower_calories_kcal=excluded.lower_calories_kcal,
                  upper_calories_kcal=excluded.upper_calories_kcal,confidence=excluded.confidence,
                  source_note=excluded.source_note,components_json=excluded.components_json,
                  per_100_g_json=excluded.per_100_g_json,revision=excluded.revision,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                recipeVersion.id,recipeVersion.recipeId,recipeVersion.versionNumber,
                recipeVersion.finishedWeightG,recipeVersion.servings,
                recipeVersion.nutrients.caloriesKcal,recipeVersion.nutrients.proteinG,
                recipeVersion.nutrients.carbohydrateG,recipeVersion.nutrients.sugarsG,
                recipeVersion.nutrients.fatG,recipeVersion.nutrients.saturatedFatG,
                recipeVersion.nutrients.fibreG,recipeVersion.nutrients.saltG,
                recipeVersion.lowerCaloriesKcal,recipeVersion.upperCaloriesKcal,
                recipeVersion.confidence,recipeVersion.sourceNote,try json(recipeVersion.components),
                try recipeVersion.per100G.map(json),recipeVersion.revision,
                FitnessDatabase.dateString(recipeVersion.updatedAt),try deviceId,
                recipeVersion.deletedAt.map(FitnessDatabase.dateString),try json(recipeVersion),
            ]
        )
    }

    private func upsert(template: FitnessMealTemplate,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_meal_templates
                (id,name,meal_key,time_relevance,favourite,active,items_json,revision,
                 client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,meal_key=excluded.meal_key,
                  time_relevance=excluded.time_relevance,favourite=excluded.favourite,
                  active=excluded.active,items_json=excluded.items_json,revision=excluded.revision,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                template.id,template.name,template.meal.rawValue,template.timeRelevance,
                template.favourite,template.active,try json(template.items),template.revision,
                FitnessDatabase.dateString(template.updatedAt),try deviceId,
                template.deletedAt.map(FitnessDatabase.dateString),try json(template),
            ]
        )
    }

    private func upsert(target: FitnessNutritionTarget,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_nutrition_targets
                (id,metric_key,target_type,target_value,target_min,target_max,training_day_value,
                 rest_day_value,phase_id,effective_from,effective_until,active,revision,
                 client_updated_at,origin_device_id,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET metric_key=excluded.metric_key,
                  target_type=excluded.target_type,target_value=excluded.target_value,
                  target_min=excluded.target_min,target_max=excluded.target_max,
                  training_day_value=excluded.training_day_value,rest_day_value=excluded.rest_day_value,
                  phase_id=excluded.phase_id,effective_from=excluded.effective_from,
                  effective_until=excluded.effective_until,active=excluded.active,
                  revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                  deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                """,
            arguments: [
                target.id,target.metric.rawValue,target.mode.rawValue,target.targetValue,
                target.targetMin,target.targetMax,target.trainingDayValue,target.restDayValue,
                target.phaseId,target.effectiveFrom,target.effectiveUntil,target.active,target.revision,
                FitnessDatabase.dateString(target.updatedAt),try deviceId,
                target.deletedAt.map(FitnessDatabase.dateString),try json(target),
            ]
        )
    }

    private func enqueue<T: Encodable>(
        _ db: Database,mutationId: String = UUID().uuidString,type: FitnessEntityType,
        id: String,baseRevision: Int?,payload: T,now: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_outbox
                (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                 base_revision,payload_json,created_at_client)
                VALUES (?,?,?,'upsert',1,?,?,?)
                """,
            arguments: [
                mutationId,type.rawValue,id,baseRevision,try json(payload),FitnessDatabase.dateString(now),
            ]
        )
    }

    private func enqueueDelete(
        _ db: Database,type: FitnessEntityType,id: String,baseRevision: Int?,now: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_outbox
                (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                 base_revision,payload_json,created_at_client)
                VALUES (?,?,?,'delete',1,?,'{}',?)
                """,
            arguments: [UUID().uuidString,type.rawValue,id,baseRevision,FitnessDatabase.dateString(now)]
        )
    }

    // MARK: Deterministic calculations and files

    private struct SourceSnapshot {
        var foodId: String?
        var nutrients: FitnessNutritionValues
    }

    private func sourceSnapshot(
        foodVersionId: String?,recipeVersionId: String?,canonicalAmount: Double,
        canonicalUnit: String,db: Database
    ) throws -> SourceSnapshot {
        if let foodVersionId {
            guard let row = try Row.fetchOne(
                db,sql: "SELECT * FROM fitness_food_versions WHERE id=? AND deleted_at IS NULL",
                arguments: [foodVersionId]
            ) else { throw FitnessNutritionRepositoryError.missingRecord }
            return try sourceSnapshot(
                foodVersion: try foodVersion(row),recipeVersion: nil,
                canonicalAmount: canonicalAmount,canonicalUnit: canonicalUnit
            )
        }
        guard let recipeVersionId,
              let row = try Row.fetchOne(
                db,sql: "SELECT * FROM fitness_recipe_versions WHERE id=? AND deleted_at IS NULL",
                arguments: [recipeVersionId]
              ) else { throw FitnessNutritionRepositoryError.missingRecord }
        return try sourceSnapshot(
            foodVersion: nil,recipeVersion: try recipeVersion(row),
            canonicalAmount: canonicalAmount,canonicalUnit: canonicalUnit
        )
    }

    private func sourceSnapshot(
        foodVersion: FitnessFoodVersion?,recipeVersion: FitnessRecipeVersion?,
        canonicalAmount: Double,canonicalUnit: String
    ) throws -> SourceSnapshot {
        if let version=foodVersion {
            guard recipeVersion == nil,canonicalUnit == version.referenceUnit else {
                throw FitnessNutritionRepositoryError.invalidLog
            }
            return SourceSnapshot(
                foodId: version.foodId,
                nutrients: version.nutrients.scaled(by: canonicalAmount/version.referenceAmount)
            )
        }
        guard let version=recipeVersion else { throw FitnessNutritionRepositoryError.missingRecord }
        let reference: Double
        if canonicalUnit == "g",let weight = version.finishedWeightG { reference = weight }
        else if canonicalUnit == "serving" { reference = version.servings ?? 1 }
        else { throw FitnessNutritionRepositoryError.invalidLog }
        return SourceSnapshot(foodId: nil,nutrients: version.nutrients.scaled(by: canonicalAmount/reference))
    }

    private func makeVersion(
        id: String,foodId: String,versionNumber: Int,draft: FitnessFoodVersionDraft,
        labelAssetId: String?,now: Date
    ) -> FitnessFoodVersion {
        // Energy conversion happens exactly once, before the immutable version is
        // persisted. Reads and analysis never reinterpret source-energy provenance.
        let calories: Double?
        if let explicit = draft.caloriesKcal { calories = explicit }
        else if let source = draft.sourceEnergyValue,draft.sourceEnergyUnit == "kcal" { calories = source }
        else if let source = draft.sourceEnergyValue,draft.sourceEnergyUnit == "kj" { calories = source/4.184 }
        else { calories = nil }
        return FitnessFoodVersion(
            id: id,foodId: foodId,versionNumber: versionNumber,effectiveFrom: FitnessDatabase.dateString(now),
            referenceAmount: draft.referenceAmount,referenceUnit: draft.referenceUnit,
            caloriesKcal: calories,sourceEnergyValue: draft.sourceEnergyValue,
            sourceEnergyUnit: draft.sourceEnergyUnit,proteinG: draft.proteinG,
            carbohydrateG: draft.carbohydrateG,sugarsG: draft.sugarsG,fatG: draft.fatG,
            saturatedFatG: draft.saturatedFatG,fibreG: draft.fibreG,saltG: draft.saltG,
            sodiumMg: draft.sodiumMg,micronutrients: draft.micronutrients,
            sourceType: draft.sourceType,sourceNote: trimmed(draft.sourceNote),confidence: draft.confidence,
            labelAssetId: labelAssetId,revision: 0,createdAt: now,updatedAt: now,deletedAt: nil
        )
    }

    private func makeRecipeVersion(
        id: String,recipeId: String,versionNumber: Int,draft: FitnessRecipeDraft,
        now: Date,db: Database
    ) throws -> FitnessRecipeVersion {
        let sortedComponents=draft.components.sorted(by: { $0.sequence < $1.sequence })
        let versionIds=Array(Set(sortedComponents.map(\.foodVersionId))).sorted()
        var versionsById: [String: FitnessFoodVersion]=[:]
        if !versionIds.isEmpty {
            let placeholders=Array(repeating:"?",count:versionIds.count).joined(separator:",")
            for row in try Row.fetchAll(
                db,sql:"SELECT * FROM fitness_food_versions WHERE id IN (\(placeholders)) AND deleted_at IS NULL",
                arguments:StatementArguments(versionIds)
            ) {
                let version=try foodVersion(row)
                versionsById[version.id]=version
            }
        }
        let componentValues = try sortedComponents.map { component in
            guard let source=versionsById[component.foodVersionId] else {
                throw FitnessNutritionRepositoryError.missingRecord
            }
            guard component.canonicalUnit == source.referenceUnit else {
                throw FitnessNutritionRepositoryError.invalidRecipe
            }
            return source.nutrients.scaled(by: component.canonicalAmount/source.referenceAmount)
        }
        var totals = FitnessNutritionValues.exactTotal(componentValues)
        if componentValues.isEmpty {
            totals = FitnessNutritionValues(
                caloriesKcal: draft.caloriesKcal,
                proteinG: nil,carbohydrateG: nil,sugarsG: nil,fatG: nil,
                saturatedFatG: nil,fibreG: nil,saltG: nil
            )
        }
        let per100 = draft.finishedWeightG.flatMap { weight in
            weight > 0 ? totals.scaled(by: 100/weight) : nil
        }
        return FitnessRecipeVersion(
            id: id,recipeId: recipeId,versionNumber: versionNumber,
            components: sortedComponents,
            finishedWeightG: draft.finishedWeightG,servings: draft.servings,nutrients: totals,
            per100G: per100,lowerCaloriesKcal: draft.lowerCaloriesKcal,
            upperCaloriesKcal: draft.upperCaloriesKcal,confidence: draft.confidence,
            sourceNote: trimmed(draft.sourceNote),revision: 0,createdAt: now,updatedAt: now,deletedAt: nil
        )
    }

    private func validate(version: FitnessFoodVersionDraft) throws {
        let nutrientValues = [
            version.caloriesKcal,version.sourceEnergyValue,version.proteinG,
            version.carbohydrateG,version.sugarsG,version.fatG,version.saturatedFatG,
            version.fibreG,version.saltG,version.sodiumMg,
        ]
        let validMicros = version.micronutrients.values.allSatisfy {
            guard let value = $0 else { return true }
            return value.isFinite && value >= 0
        }
        guard version.referenceAmount.isFinite,version.referenceAmount > 0,!version.referenceUnit.isEmpty,
              (version.sourceEnergyValue == nil) == (version.sourceEnergyUnit == nil),
              nutrientValues.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }),validMicros,
              version.sourceEnergyUnit.map({ $0 == "kcal" || $0 == "kj" }) ?? true else {
            throw FitnessNutritionRepositoryError.invalidVersion
        }
    }

    private func validRecipeDraft(_ draft: FitnessRecipeDraft,requiresName: Bool) -> Bool {
        if requiresName && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        guard draft.components.allSatisfy({
            $0.amount.isFinite && $0.amount > 0 && $0.canonicalAmount.isFinite && $0.canonicalAmount > 0
                && !$0.unit.isEmpty && !$0.canonicalUnit.isEmpty
        }) else { return false }
        func positive(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 > 0 } ?? true }
        func nonnegative(_ value: Double?) -> Bool { value.map { $0.isFinite && $0 >= 0 } ?? true }
        guard positive(draft.finishedWeightG),positive(draft.servings),nonnegative(draft.caloriesKcal),
              nonnegative(draft.lowerCaloriesKcal),nonnegative(draft.upperCaloriesKcal) else { return false }
        if let lower=draft.lowerCaloriesKcal,let upper=draft.upperCaloriesKcal,lower > upper { return false }
        return !draft.components.isEmpty || draft.caloriesKcal != nil
            || (draft.lowerCaloriesKcal != nil && draft.upperCaloriesKcal != nil)
    }

    private func stageLabel(
        _ label: FitnessNutritionLabelDraft,assetId: String
    ) throws -> StagedPrivateLabel {
        try Task.checkCancellation()
        let ownerIdentity = try requireOwnerIdentity()
        guard let root = database.activeStoreURL?
            .deletingLastPathComponent().standardizedFileURL,
              database.activeIdentity == ownerIdentity else {
            throw FitnessNutritionRepositoryError.inactiveProfile
        }
        let mediaType = label.mediaType.lowercased()
        let allowed = ["image/jpeg","image/png","image/heic","image/heif"]
        guard label.ownerIdentity == ownerIdentity,
              label.byteCount > 0,
              label.byteCount <= FitnessNutritionLabelDraft.maximumByteCount,
              allowed.contains(mediaType),
              isSafeLabelFilename(label.originalFilename,mediaType: mediaType) else {
            throw FitnessNutritionRepositoryError.invalidLabel
        }
        let sourceDirectory = label.stagedFile.directoryURL.standardizedFileURL
        let source = label.fileURL.standardizedFileURL
        let sourceDirectoryValues = try sourceDirectory.resourceValues(forKeys: [
            .isDirectoryKey,.isSymbolicLinkKey,
        ])
        guard UUID(uuidString: sourceDirectory.lastPathComponent) != nil,
              source.deletingLastPathComponent() == sourceDirectory,
              source.lastPathComponent == "original",
              sourceDirectoryValues.isDirectory == true,
              sourceDirectoryValues.isSymbolicLink != true else {
            throw FitnessNutritionRepositoryError.invalidLabel
        }
        let verifiedSourceBytes = try PhotoUploadPrep.validatedStagedImageByteCount(
            label.stagedFile,
            declaredTypeIdentifiers: []
        )
        guard verifiedSourceBytes == label.byteCount,
              let sourceMetadata = PhotoUploadPrep.fileMetadata(at: source),
              sourceMetadata.mediaType == mediaType else {
            throw FitnessNutritionRepositoryError.invalidLabel
        }

        try beforeLabelFilePublication?()
        let directory = root.appendingPathComponent("PrivateRequired/NutritionLabels",isDirectory: true)
        try LocalFileProtection.prepareDirectory(directory,fileManager: fileManager)
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw FitnessNutritionRepositoryError.unsafePath
        }
        let ext: String
        switch label.mediaType.lowercased() {
        case "image/png": ext = "png"
        case "image/heic": ext = "heic"
        case "image/heif": ext = "heif"
        default: ext = "jpg"
        }
        let filename = "\(assetId.lowercased()).\(ext)"
        let url = directory.appendingPathComponent(filename).standardizedFileURL
        let temporaryURL = directory.appendingPathComponent(
            ".\(assetId.lowercased()).staging"
        ).standardizedFileURL
        guard url.deletingLastPathComponent() == directory.standardizedFileURL,
              temporaryURL.deletingLastPathComponent() == directory.standardizedFileURL,
              !fileManager.fileExists(atPath: url.path),
              !fileManager.fileExists(atPath: temporaryURL.path) else {
            throw FitnessNutritionRepositoryError.unsafePath
        }
        guard try !symbolicLinkExists(at:url),
              try !symbolicLinkExists(at:temporaryURL),
              fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.protectionKey: LocalFileProtection.sensitive]
              ) else {
            throw FitnessNutritionRepositoryError.unsafePath
        }

        var keepPublishedFile = false
        defer {
            removePrivateLabelArtifactIfPresent(
                temporaryURL,context:"nutrition-label staging"
            )
            if !keepPublishedFile {
                removePrivateLabelArtifactIfPresent(
                    url,context:"failed nutrition-label publication"
                )
            }
        }
        let copiedBytes = try copyLabelBytes(
            from: source,
            to: temporaryURL,
            expectedByteCount: verifiedSourceBytes
        )
        let copied = PhotoUploadPrep.StagedFile(
            directoryURL: directory,
            fileURL: temporaryURL
        )
        let verifiedDestinationBytes = try PhotoUploadPrep.validatedStagedImageByteCount(
            copied,
            declaredTypeIdentifiers: []
        )
        guard copiedBytes == verifiedDestinationBytes,
              copiedBytes == label.byteCount,
              let destinationMetadata = PhotoUploadPrep.fileMetadata(at: temporaryURL),
              destinationMetadata.mediaType == mediaType else {
            throw FitnessNutritionRepositoryError.invalidLabel
        }
        try LocalFileProtection.protectItem(at: temporaryURL,fileManager: fileManager)
        try fileManager.moveItem(at: temporaryURL,to: url)
        let finalValues = try url.resourceValues(forKeys: [
            .fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey,
        ])
        guard finalValues.isRegularFile == true,
              finalValues.isSymbolicLink != true,
              finalValues.fileSize == verifiedDestinationBytes else {
            throw FitnessNutritionRepositoryError.invalidLabel
        }
        try LocalFileProtection.protectItem(at: url,fileManager: fileManager)
        keepPublishedFile = true
        return StagedPrivateLabel(
            ownerIdentity: ownerIdentity,
            profileRoot: root,
            relativePath: "PrivateRequired/NutritionLabels/\(filename)",
            originalFilename: label.originalFilename,
            mediaType: mediaType,
            byteCount: verifiedDestinationBytes
        )
    }

    private func insertPendingLabel(
        _ db: Database,assetId: String,entityType: FitnessEntityType,entityId: String,
        mutationId: String,staged: StagedPrivateLabel,now: Date
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_private_file_uploads
                (asset_id,domain_entity_id,asset_kind,storage_class,relative_path,
                 original_filename,media_type,byte_count,state,created_at,
                 dependent_entity_type,dependent_mutation_id)
                VALUES (?,?,'nutrition_label','private_required',?,?,?,?, 'pending_upload',?,?,?)
            """,
            arguments: [
                assetId,entityId,staged.relativePath,staged.originalFilename,staged.mediaType,
                staged.byteCount,FitnessDatabase.dateString(now),entityType.rawValue,mutationId,
            ]
        )
    }

    private func validateLabelCommitContext(_ staged: StagedPrivateLabel) throws {
        guard database.activeIdentity == staged.ownerIdentity,
              database.activeStoreURL?.deletingLastPathComponent().standardizedFileURL
                == staged.profileRoot else {
            throw FitnessNutritionRepositoryError.inactiveProfile
        }
    }

    private func removePrivateLabelArtifactIfPresent(_ url:URL,context:String) {
        do {
            let values = try url.resourceValues(forKeys:[
                .isRegularFileKey,.isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,values.isSymbolicLink != true else {
                fitnessNutritionRepositoryLogger.error(
                    "Refused non-regular cleanup target after \(context, privacy: .public)."
                )
                return
            }
            try fileManager.removeItem(at:url)
        } catch let error as CocoaError where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        } catch {
            fitnessNutritionRepositoryLogger.error(
                "Cleanup failed after \(context, privacy: .public); launch reconciliation will retry: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func symbolicLinkExists(at url:URL) throws -> Bool {
        do {
            _ = try fileManager.destinationOfSymbolicLink(atPath:url.path)
            return true
        } catch let error as CocoaError where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private static func closeFileHandleAfterFallback(
        _ handle:FileHandle,context:String
    ) {
        do {
            try handle.close()
        } catch {
            fitnessNutritionRepositoryLogger.error(
                "File-handle cleanup failed after \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func copyLabelBytes(
        from source: URL,
        to destination: URL,
        expectedByteCount: Int
    ) throws -> Int {
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        var inputIsOpen = true
        var outputIsOpen = true
        defer {
            if inputIsOpen {
                Self.closeFileHandleAfterFallback(
                    input,context:"nutrition-label source copy"
                )
            }
            if outputIsOpen {
                Self.closeFileHandleAfterFallback(
                    output,context:"nutrition-label staging copy"
                )
            }
        }
        var copiedBytes = 0
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: 1_024 * 1_024) ?? Data()
            guard !chunk.isEmpty else { break }
            let (nextCount,overflow) = copiedBytes.addingReportingOverflow(chunk.count)
            guard !overflow,
                  nextCount <= expectedByteCount,
                  nextCount <= FitnessNutritionLabelDraft.maximumByteCount else {
                throw FitnessNutritionRepositoryError.invalidLabel
            }
            try output.write(contentsOf: chunk)
            copiedBytes = nextCount
        }
        try Task.checkCancellation()
        try output.synchronize()
        try Task.checkCancellation()
        guard copiedBytes == expectedByteCount else {
            throw FitnessNutritionRepositoryError.invalidLabel
        }
        try input.close()
        inputIsOpen = false
        try output.close()
        outputIsOpen = false
        return copiedBytes
    }

    private func isSafeLabelFilename(_ filename: String,mediaType: String) -> Bool {
        guard !filename.isEmpty,
              filename.count <= 240,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch mediaType {
        case "image/jpeg": return fileExtension == "jpg" || fileExtension == "jpeg"
        case "image/png": return fileExtension == "png"
        case "image/heic": return fileExtension == "heic"
        case "image/heif": return fileExtension == "heif"
        default: return false
        }
    }

    private func absoluteURL(relativePath: String) throws -> URL {
        guard let root = database.activeStoreURL?.deletingLastPathComponent().standardizedFileURL else {
            throw FitnessDatabaseError.notActive
        }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path+"/") else { throw FitnessNutritionRepositoryError.unsafePath }
        return url
    }

    private func privateLabelURL(relativePath: String) throws -> URL {
        guard let root = database.activeStoreURL?
            .deletingLastPathComponent().standardizedFileURL else {
            throw FitnessDatabaseError.notActive
        }
        let directory = root.appendingPathComponent(
            "PrivateRequired/NutritionLabels",isDirectory: true
        ).standardizedFileURL
        let url = try absoluteURL(relativePath: relativePath)
        guard url.deletingLastPathComponent() == directory,
              Self.isOwnedNutritionLabelFilename(url.lastPathComponent) else {
            throw FitnessNutritionRepositoryError.unsafePath
        }
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw FitnessNutritionRepositoryError.unsafePath
            }
        }
        return url
    }

    private static func isOwnedNutritionLabelFilename(_ filename: String) -> Bool {
        let allowedExtensions = ["jpg","png","heic","heif"]
        guard let fileExtension = allowedExtensions.first(where: {
            filename.hasSuffix(".\($0)")
        }) else { return false }
        let suffix = ".\(fileExtension)"
        let uuid = String(filename.dropLast(suffix.count))
        return uuid.count == 36
            && uuid == uuid.lowercased()
            && UUID(uuidString: uuid) != nil
    }

    private static func isOwnedNutritionLabelArtifactFilename(_ filename: String) -> Bool {
        if isOwnedNutritionLabelFilename(filename) { return true }
        let prefix = "."
        let suffix = ".staging"
        guard filename.hasPrefix(prefix),filename.hasSuffix(suffix) else { return false }
        let uuid = String(filename.dropFirst(prefix.count).dropLast(suffix.count))
        return uuid.count == 36
            && uuid == uuid.lowercased()
            && UUID(uuidString: uuid) != nil
    }

    private static func isReclaimableNutritionLabelCandidate(
        _ url: URL,
        directory: URL,
        referenced: Set<String>,
        keys: Set<URLResourceKey>,
        cutoff: Date
    ) throws -> Bool {
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory,
              !referenced.contains(candidate.lastPathComponent),
              isOwnedNutritionLabelArtifactFilename(candidate.lastPathComponent) else {
            return false
        }
        let values = try candidate.resourceValues(forKeys: keys)
        guard
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let date = values.contentModificationDate ?? values.creationDate else { return false }
        return date <= cutoff
    }

    private func per100Calories(_ version: FitnessFoodVersion) -> Double? {
        guard version.referenceUnit == "g",version.referenceAmount > 0,
              let calories = version.caloriesKcal else { return nil }
        return calories*100/version.referenceAmount
    }

    private func nutrient(_ values: FitnessNutritionValues,metric: FitnessNutritionMetric) -> Double? {
        switch metric {
        case .caloriesKcal: values.caloriesKcal
        case .proteinG: values.proteinG
        case .carbohydrateG: values.carbohydrateG
        case .fibreG: values.fibreG
        case .fatG: values.fatG
        case .saturatedFatG: values.saturatedFatG
        case .sugarsG: values.sugarsG
        case .saltG: values.saltG
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value),as: UTF8.self)
    }

    private func cache<T: Encodable>(_ value: T,key: String) throws {
        let owner = try requireOwnerIdentity()
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_experience_cache(owner_identity,cache_key,payload_json,updated_at)
                    VALUES (?,?,?,?)
                    ON CONFLICT(owner_identity,cache_key) DO UPDATE SET
                      payload_json=excluded.payload_json,updated_at=excluded.updated_at
                    """,
                arguments: [owner,key,try json(value),FitnessDatabase.dateString(Date())]
            )
        }
    }

    private func cached<T: Decodable>(_ type: T.Type,key: String) throws -> T? {
        let owner = try requireOwnerIdentity()
        let payload = try database.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT payload_json FROM fitness_experience_cache
                    WHERE owner_identity=? AND cache_key=?
                    """,
                arguments: [owner,key]
            )
        }
        return try decode(type,payload)
    }

    private func requireOwnerIdentity() throws -> String {
        guard let identity=database.activeIdentity else {
            throw FitnessNutritionRepositoryError.inactiveProfile
        }
        return identity
    }

    private func decode<T: Decodable>(_ type: T.Type,_ value: String?) throws -> T? {
        guard let value else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = FitnessDatabase.date(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,debugDescription: "Invalid date"))
            }
            return date
        }
        return try decoder.decode(type,from: Data(value.utf8))
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

// MARK: Sync wire payloads

private struct FoodVersionMutation: Encodable {
    let id: String
    let foodId: String?
    let referenceAmount: Double
    let referenceUnit: String
    let caloriesKcal: Double?
    let sourceEnergyValue: Double?
    let sourceEnergyUnit: String?
    let proteinG: Double?
    let carbohydrateG: Double?
    let sugarsG: Double?
    let fatG: Double?
    let saturatedFatG: Double?
    let fibreG: Double?
    let saltG: Double?
    let sodiumMg: Double?
    let micronutrients: [String: Double?]
    let sourceType: String
    let sourceNote: String?
    let confidence: String
    let labelAssetId: String?

    init(version: FitnessFoodVersion,includeFoodId: Bool) {
        id=version.id; foodId=includeFoodId ? version.foodId : nil
        referenceAmount=version.referenceAmount; referenceUnit=version.referenceUnit
        caloriesKcal=version.caloriesKcal; sourceEnergyValue=version.sourceEnergyValue
        sourceEnergyUnit=version.sourceEnergyUnit; proteinG=version.proteinG
        carbohydrateG=version.carbohydrateG; sugarsG=version.sugarsG; fatG=version.fatG
        saturatedFatG=version.saturatedFatG; fibreG=version.fibreG; saltG=version.saltG
        sodiumMg=version.sodiumMg; micronutrients=version.micronutrients
        sourceType=version.sourceType; sourceNote=version.sourceNote; confidence=version.confidence
        labelAssetId=version.labelAssetId
    }
}

private struct FoodMutation: Encodable {
    let id: String
    let name: String
    let brand: String?
    let categoryKey: String?
    let barcode: String?
    let notes: String?
    let householdShared: Bool
    let favourite: Bool
    let active: Bool
    let version: FoodVersionMutation?
}

private struct FoodServingMutation: Encodable {
    let id: String
    let foodId: String
    let name: String
    let amount: Double
    let unit: String
    let canonicalAmount: Double
    let canonicalUnit: String
    let measurementQuality: String
    let isDefault: Bool
    let active: Bool

    init(serving: FitnessFoodServing) {
        id=serving.id; foodId=serving.foodId; name=serving.name; amount=serving.amount
        unit=serving.unit; canonicalAmount=serving.canonicalAmount; canonicalUnit=serving.canonicalUnit
        measurementQuality=serving.measurementQuality.rawValue; isDefault=serving.isDefault; active=serving.active
    }
}

private struct FoodLogMutation: Encodable {
    let id: String
    let foodVersionId: String?
    let recipeVersionId: String?
    let loggedAtUtc: Date
    let localTimezone: String
    let mealKey: String
    let enteredAmount: Double
    let enteredUnit: String
    let canonicalAmount: Double
    let canonicalUnit: String
    let measurementQuality: String
    let notes: String?
    let contextTags: [String]

    init(entry: FitnessFoodLogEntry) {
        id=entry.id; foodVersionId=entry.foodVersionId; recipeVersionId=entry.recipeVersionId
        loggedAtUtc=entry.loggedAt; localTimezone=entry.localTimezone; mealKey=entry.meal.rawValue
        enteredAmount=entry.enteredAmount; enteredUnit=entry.enteredUnit
        canonicalAmount=entry.canonicalAmount; canonicalUnit=entry.canonicalUnit
        measurementQuality=entry.measurementQuality.rawValue; notes=entry.notes; contextTags=entry.contextTags
    }
}

private struct RecipeComponentMutation: Encodable {
    let foodVersionId: String
    let amount: Double
    let unit: String
    let canonicalAmount: Double
    let canonicalUnit: String
    let sequence: Int
}

private struct RecipeVersionMutation: Encodable {
    let id: String
    let recipeId: String?
    let components: [RecipeComponentMutation]
    let finishedWeightG: Double?
    let servings: Double?
    let caloriesKcal: Double?
    let proteinG: Double?
    let carbohydrateG: Double?
    let sugarsG: Double?
    let fatG: Double?
    let saturatedFatG: Double?
    let fibreG: Double?
    let saltG: Double?
    let lowerCaloriesKcal: Double?
    let upperCaloriesKcal: Double?
    let confidence: String
    let sourceNote: String?

    init(version: FitnessRecipeVersion,includeRecipeId: Bool) {
        id=version.id; recipeId=includeRecipeId ? version.recipeId : nil
        components=version.components.map {
            RecipeComponentMutation(
                foodVersionId: $0.foodVersionId,amount: $0.amount,unit: $0.unit,
                canonicalAmount: $0.canonicalAmount,canonicalUnit: $0.canonicalUnit,sequence: $0.sequence
            )
        }
        finishedWeightG=version.finishedWeightG; servings=version.servings
        caloriesKcal=version.nutrients.caloriesKcal; proteinG=version.nutrients.proteinG
        carbohydrateG=version.nutrients.carbohydrateG; sugarsG=version.nutrients.sugarsG
        fatG=version.nutrients.fatG; saturatedFatG=version.nutrients.saturatedFatG
        fibreG=version.nutrients.fibreG; saltG=version.nutrients.saltG
        lowerCaloriesKcal=version.lowerCaloriesKcal; upperCaloriesKcal=version.upperCaloriesKcal
        confidence=version.confidence; sourceNote=version.sourceNote
    }
}

private struct RecipeMutation: Encodable {
    let id: String
    let name: String
    let notes: String?
    let householdShared: Bool
    let favourite: Bool
    let active: Bool
    let version: RecipeVersionMutation?

    init(recipe: FitnessRecipe,version: RecipeVersionMutation?) {
        id=recipe.id; name=recipe.name; notes=recipe.notes; householdShared=recipe.householdShared
        favourite=recipe.favourite; active=recipe.active; self.version=version
    }
}

private struct MealTemplateItemMutation: Encodable {
    let id: String
    let foodVersionId: String?
    let recipeVersionId: String?
    let amount: Double
    let unit: String
    let canonicalAmount: Double
    let canonicalUnit: String
    let measurementQuality: String
    let sequence: Int
}

private struct MealTemplateMutation: Encodable {
    let id: String
    let name: String
    let mealKey: String
    let timeRelevance: String?
    let favourite: Bool
    let active: Bool
    let items: [MealTemplateItemMutation]

    init(template: FitnessMealTemplate) {
        id=template.id; name=template.name; mealKey=template.meal.rawValue
        timeRelevance=template.timeRelevance; favourite=template.favourite; active=template.active
        items=template.items.map {
            MealTemplateItemMutation(
                id: $0.id,foodVersionId: $0.foodVersionId,recipeVersionId: $0.recipeVersionId,
                amount: $0.amount,unit: $0.unit,canonicalAmount: $0.canonicalAmount,
                canonicalUnit: $0.canonicalUnit,measurementQuality: $0.measurementQuality.rawValue,
                sequence: $0.sequence
            )
        }
    }
}

private struct NutritionTargetMutation: Encodable {
    let id: String
    let metricKey: String
    let targetType: String
    let targetValue: Double?
    let targetMin: Double?
    let targetMax: Double?
    let trainingDayValue: Double?
    let restDayValue: Double?
    let phaseId: String?
    let effectiveFrom: String
    let effectiveUntil: String?
    let active: Bool

    init(target: FitnessNutritionTarget) {
        id=target.id; metricKey=target.metric.rawValue; targetType=target.mode.rawValue
        targetValue=target.targetValue; targetMin=target.targetMin; targetMax=target.targetMax
        trainingDayValue=target.trainingDayValue; restDayValue=target.restDayValue
        phaseId=target.phaseId; effectiveFrom=target.effectiveFrom
        effectiveUntil=target.effectiveUntil; active=target.active
    }
}
