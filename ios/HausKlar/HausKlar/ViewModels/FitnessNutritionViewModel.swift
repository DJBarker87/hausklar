import Foundation
import UIKit

/// Keeps staged picker files recoverably owned even when the main-actor view
/// model is released. A separate lock-protected lifetime object avoids Swift's
/// back-deployed `isolated deinit` thunk while still making cleanup safe if
/// destruction happens away from the main actor.
private final class FitnessNutritionPhotoDraftLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var mealStagedFile: PhotoUploadPrep.StagedFile?
    private var labelStagedFile: PhotoUploadPrep.StagedFile?

    func ownMeal(_ stagedFile: PhotoUploadPrep.StagedFile) {
        replace(meal: stagedFile, label: nil)
    }

    func ownLabel(_ stagedFile: PhotoUploadPrep.StagedFile) {
        replace(meal: nil, label: stagedFile)
    }

    func relinquishLabel() {
        lock.lock()
        labelStagedFile = nil
        lock.unlock()
    }

    func discard() {
        let files = takeOwnedFiles()
        Self.remove(files)
    }

    private func replace(
        meal: PhotoUploadPrep.StagedFile?,
        label: PhotoUploadPrep.StagedFile?
    ) {
        lock.lock()
        let previous = (mealStagedFile, labelStagedFile)
        mealStagedFile = meal
        labelStagedFile = label
        lock.unlock()
        Self.remove(previous)
    }

    private func takeOwnedFiles() -> (
        PhotoUploadPrep.StagedFile?,
        PhotoUploadPrep.StagedFile?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let files = (mealStagedFile, labelStagedFile)
        mealStagedFile = nil
        labelStagedFile = nil
        return files
    }

    private static func remove(_ files: (
        PhotoUploadPrep.StagedFile?,
        PhotoUploadPrep.StagedFile?
    )) {
        if let meal = files.0 {
            PhotoUploadPrep.removeStagedFile(meal)
        }
        if let label = files.1 {
            PhotoUploadPrep.removeStagedFile(label)
        }
    }

    deinit {
        lock.lock()
        let files = (mealStagedFile, labelStagedFile)
        mealStagedFile = nil
        labelStagedFile = nil
        lock.unlock()
        Self.remove(files)
    }
}

/// Owns temporary nutrition-picker files until a view either replaces them or
/// hands the label to the repository. Generation tokens make a cancelled load
/// incapable of installing a late result over the user's newer selection.
@MainActor
final class FitnessNutritionPhotoDraftOwner: ObservableObject {
    @Published private(set) var mealPreview: UIImage?
    @Published private(set) var mealStagedFile: PhotoUploadPrep.StagedFile?
    @Published private(set) var labelDraft: FitnessNutritionLabelDraft?

    private var generation = UUID()
    private let lifetime = FitnessNutritionPhotoDraftLifetime()

    @discardableResult
    func beginReplacement() -> UUID {
        discardOwnedFiles()
        generation = UUID()
        return generation
    }

    @discardableResult
    func installMealPhoto(
        _ stagedFile: PhotoUploadPrep.StagedFile,
        preview: UIImage,
        generation expectedGeneration: UUID
    ) -> Bool {
        guard generation == expectedGeneration else {
            PhotoUploadPrep.removeStagedFile(stagedFile)
            return false
        }
        discardOwnedFiles()
        lifetime.ownMeal(stagedFile)
        mealStagedFile = stagedFile
        mealPreview = preview
        return true
    }

    @discardableResult
    func installLabel(
        _ draft: FitnessNutritionLabelDraft,
        generation expectedGeneration: UUID
    ) -> Bool {
        guard generation == expectedGeneration else {
            PhotoUploadPrep.removeStagedFile(draft.stagedFile)
            return false
        }
        discardOwnedFiles()
        lifetime.ownLabel(draft.stagedFile)
        labelDraft = draft
        return true
    }

    /// Transfers the sole cleanup responsibility to the save operation. This
    /// prevents dismissal or an account change from deleting the source while
    /// the repository is still streaming it into the owner-scoped store.
    func takeLabelDraft() -> FitnessNutritionLabelDraft? {
        let draft = labelDraft
        if draft != nil {
            lifetime.relinquishLabel()
        }
        labelDraft = nil
        return draft
    }

    func discard() {
        generation = UUID()
        discardOwnedFiles()
    }

    private func discardOwnedFiles() {
        lifetime.discard()
        mealStagedFile = nil
        mealPreview = nil
        labelDraft = nil
    }
}

@MainActor
final class FitnessNutritionViewModel: FitnessViewModelBase {
    static let defaultAnalysisPeriodDays=14
    @Published var foods: [FitnessFood] = []
    @Published var recipes: [FitnessRecipe] = []
    @Published var templates: [FitnessMealTemplate] = []
    @Published var targets: [FitnessNutritionTarget] = []
    @Published var labels: [FitnessPendingNutritionLabel] = []
    @Published var settings = FitnessNutritionSettings(
        id: "nutrition-settings",timezone: TimeZone.current.identifier,
        nutritionDayStartMinutes: 240,revision: 0
    )
    @Published var selectedDate = Date()
    @Published var day = FitnessNutritionDay(
        nutritionDate: "",entries: [],totals: .unknown,
        uncertainMetrics: [],measuredShare: nil,estimatedShare: nil
    )
    @Published var search = ""
    @Published var includeArchived = false
    @Published var statusMessage: String?
    @Published var analysis: FitnessNutritionAnalysis?
    @Published var analysisPeriodDays=FitnessNutritionViewModel.defaultAnalysisPeriodDays
    @Published var isLoadingAnalysis = false
    @Published var analysisErrorMessage: String?
    @Published var isLookingUpBarcode=false
    @Published var barcodeLookupError:String?
    @Published var isLookingUpFood=false
    @Published var foodLookupError:String?
    @Published private(set) var quickLogUndo:FitnessFoodLogEntry?
    @Published var plannedMeals:[FitnessPlannedHouseholdMeal]=[]
    @Published var pendingPlannedMealLogs:[FitnessPlannedMealLogDraft]=[]
    @Published var loggedPlannedMealIds:Set<String>=[]
    @Published var householdMeals:[FitnessHouseholdMeal]=[]
    @Published var householdMealLinks:[FitnessHouseholdMealLink]=[]

    private let repository: FitnessNutritionRepository
    private let service: FitnessNutritionService
    private var analysisRequestId=UUID()

    init(
        repository: FitnessNutritionRepository = .shared,
        service: FitnessNutritionService = .shared,
        database: FitnessDatabase = .shared
    ) {
        self.repository = repository
        self.service = service
        super.init(database: database)
    }

    func load() async {
        await run { try await self.reloadLocal() }
        await loadAnalysis()
    }

    func loadLogHome(refresh:Bool=false) async {
        await run {
            try await self.reloadLocal()
            self.quickLogUndo=try await self.repository.quickLogUndo()
        }
        guard !day.nutritionDate.isEmpty else { return }
        do {
            try await withFitnessStore {
                async let planned=service.plannedMeals(on:day.nutritionDate,refresh:refresh)
                async let pending=service.pendingPlannedMealLogs()
                async let logged=repository.loggedPlannedMealIds()
                plannedMeals=try await planned
                pendingPlannedMealLogs=try await pending
                loggedPlannedMealIds=try await logged
            }
        } catch {
            // The diary and saved quick choices remain fully usable. Optional
            // household suggestions do not replace the primary logging flow.
            recordRecoverableFailure(
                section:"Planned meals",
                userMessage:"Planned-meal suggestions could not be loaded. The diary is still available.",
                error:error
            )
        }
    }

    func refreshLogHome() async {
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch is CancellationError {
            return
        } catch {
            recordRecoverableFailure(
                section:"Nutrition refresh",
                userMessage:"Saved entries are available; syncing will retry automatically.",
                error:error
            )
        }
        await loadLogHome(refresh:true)
    }

    func refresh() async {
        do { try await FitnessSyncService.shared.syncNow() }
        catch { errorMessage = error.localizedDescription }
        await run { try await self.reloadLocal() }
        await loadAnalysis(refresh: true)
    }

    func selectDate(_ value: Date) async {
        selectedDate = value
        analysis = nil
        await run { self.day = try await self.repository.day(on: value) }
        await loadAnalysis()
    }

    /// Diary navigation does not need to recompute the longer-range analysis.
    func selectLogDate(_ value:Date) async {
        selectedDate=value
        analysis=nil
        await loadLogHome()
    }

    func selectAnalysisPeriod(_ days: Int) async {
        guard [7,14,28,90].contains(days),analysisPeriodDays != days else { return }
        analysisPeriodDays = days
        analysis = nil
        await loadAnalysis()
    }

    func loadAnalysis(refresh: Bool = false) async {
        guard let range=analysisRange() else { return }
        let requestId=UUID()
        analysisRequestId=requestId
        isLoadingAnalysis=true
        analysisErrorMessage=nil
        defer {
            if analysisRequestId == requestId { isLoadingAnalysis=false }
        }
        do {
            let value=try await service.analysis(
                start:range.start,end:range.end,refresh:refresh
            )
            guard analysisRequestId == requestId else { return }
            analysis=value
        } catch {
            guard analysisRequestId == requestId else { return }
            analysisErrorMessage=error.localizedDescription
        }
    }

    func searchFoods() async {
        await run {
            self.foods = try await self.repository.foods(
                search: self.search,includeArchived: self.includeArchived
            )
        }
    }

    func createFood(_ draft: FitnessFoodDraft,label: FitnessNutritionLabelDraft?) async -> Bool {
        defer {
            if let label { PhotoUploadPrep.removeStagedFile(label.stagedFile) }
        }
        return await mutate(success: "Food saved") {
            _ = try await self.repository.createFood(draft,label: label)
        }
    }

    func copyFoodToMine(_ food: FitnessFood) async -> Bool {
        guard let version = food.currentVersion else { return false }
        return await createFood(
            FitnessFoodDraft(
                name: "\(food.name) copy",brand: food.brand,categoryKey: food.categoryKey,
                barcode: nil,notes: food.notes,householdShared: false,favourite: false,
                version: FitnessFoodVersionDraft(
                    referenceAmount: version.referenceAmount,referenceUnit: version.referenceUnit,
                    caloriesKcal: version.caloriesKcal,sourceEnergyValue: version.sourceEnergyValue,
                    sourceEnergyUnit: version.sourceEnergyUnit,proteinG: version.proteinG,
                    carbohydrateG: version.carbohydrateG,sugarsG: version.sugarsG,fatG: version.fatG,
                    saturatedFatG: version.saturatedFatG,fibreG: version.fibreG,saltG: version.saltG,
                    sodiumMg: version.sodiumMg,micronutrients: version.micronutrients,
                    sourceType: "manual",sourceNote: "Copied from household food \(food.name)",
                    confidence: version.confidence
                )
            ),label: nil
        )
    }

    func addVersion(foodId: String,draft: FitnessFoodVersionDraft,label: FitnessNutritionLabelDraft?) async -> Bool {
        defer {
            if let label { PhotoUploadPrep.removeStagedFile(label.stagedFile) }
        }
        return await mutate(success: "New nutrition details saved") {
            _ = try await self.repository.addFoodVersion(foodId: foodId,draft: draft,label: label)
        }
    }

    func saveFood(_ food: FitnessFood) async -> Bool {
        await mutate(success: "Food updated") { _ = try await self.repository.saveFoodIdentity(food) }
    }

    func addServing(foodId: String,draft: FitnessFoodServingDraft) async -> Bool {
        await mutate(success: "Serving alias saved") {
            _ = try await self.repository.addServing(foodId: foodId,draft: draft)
        }
    }

    /// `entryId` is the caller's stable id for one logging intent. Passing the
    /// id the editor minted when it opened turns a second tap, or a retry after
    /// an error, into an update of that entry rather than a second diary copy.
    func saveLog(
        _ draft: FitnessFoodLogDraft,editing: FitnessFoodLogEntry? = nil,entryId: String? = nil
    ) async -> Bool {
        let usageRun = UsageMonitor.start(.saveFoodLog)
        var saved: FitnessFoodLogEntry?
        var succeeded = false
        await run {
            saved = try await self.repository.saveLog(
                draft,id: editing?.id ?? entryId ?? UUID().uuidString,baseRevision: editing?.revision
            )
            try await self.reloadLocal()
            self.statusMessage = editing == nil ? "Added to diary" : "Diary entry updated"
            if editing == nil,let saved {
                self.quickLogUndo = saved
                try await self.repository.setQuickLogUndo(saved)
            }
            succeeded = true
            HapticManager.success()
            scheduleFitnessSync(after:"food log")
        }
        if succeeded {
            UsageMonitor.complete(usageRun)
        } else {
            UsageMonitor.fail(usageRun, category: .unknown)
        }
        return succeeded
    }

    func saveMealLogs(_ drafts: [FitnessFoodLogDraft],entryIds: [String]? = nil) async -> Bool {
        guard !drafts.isEmpty else { return true }
        guard entryIds == nil || entryIds?.count == drafts.count else { return false }
        let usageRun = UsageMonitor.start(.saveMealLogs)
        var succeeded = false
        await run {
            for (index,draft) in drafts.enumerated() {
                _ = try await self.repository.saveLog(
                    draft,id: entryIds?[index] ?? UUID().uuidString
                )
            }
            try await self.reloadLocal()
            self.statusMessage = "Meal added to diary"
            succeeded = true
            HapticManager.success()
            scheduleFitnessSync(after: "completed meal")
        }
        if succeeded {
            UsageMonitor.complete(usageRun)
        } else {
            UsageMonitor.fail(usageRun, category: .unknown)
        }
        return succeeded
    }

    func lookupBarcode(_ raw:String) async -> FitnessFoodBarcodeLookup? {
        let barcode=raw.filter(\.isNumber)
        guard (8...14).contains(barcode.count),!isLookingUpBarcode else {
            barcodeLookupError="Enter an 8–14 digit barcode."
            return nil
        }
        isLookingUpBarcode=true; barcodeLookupError=nil
        defer { isLookingUpBarcode=false }
        do { return try await service.barcodeLookup(barcode) }
        catch { barcodeLookupError=error.localizedDescription; return nil }
    }

    func lookupFoods(named raw: String) async -> [FitnessFoodBarcodeLookup] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, !isLookingUpFood else {
            foodLookupError = "Enter at least two characters."
            return []
        }
        isLookingUpFood = true
        foodLookupError = nil
        defer { isLookingUpFood = false }
        do {
            let values = try await service.foodSearch(query)
            if values.isEmpty { foodLookupError = "No packaged foods matched \(query)." }
            return values
        } catch {
            foodLookupError = error.localizedDescription
            return []
        }
    }

    func createLookupFood(_ lookup: FitnessFoodBarcodeLookup) async -> FitnessFood? {
        var created: FitnessFood?
        await run {
            created = try await self.repository.createFood(lookup.reviewDraft)
            try await self.reloadLocal()
            self.statusMessage = "Food saved"
            scheduleFitnessSync(after: "looked-up food")
        }
        return created
    }

    func quickLog(_ food:FitnessFood,meal requestedMeal:FitnessMeal?=nil) async -> Bool {
        guard let version=food.currentVersion else { return false }
        let usageRun = UsageMonitor.start(.quickLogFood)
        let meal=requestedMeal ?? food.quickUse?.recentMealKeys.first ?? Self.mealForCurrentTime()
        let amount=quickAmount(food:food,version:version)
        var saved:FitnessFoodLogEntry?
        await run {
            saved=try await self.repository.saveLog(FitnessFoodLogDraft(
                foodVersionId:version.id,recipeVersionId:nil,label:food.name,
                loggedAt:Date(),localTimezone:TimeZone.current.identifier,meal:meal,
                enteredAmount:amount.entered,enteredUnit:amount.enteredUnit,
                canonicalAmount:amount.canonical,canonicalUnit:amount.canonicalUnit,
                measurementQuality:amount.quality,notes:nil,contextTags:[]
            ))
            try await self.reloadLocal()
            self.statusMessage="Added \(food.name) to \(meal.title)"
            self.quickLogUndo=saved
            if let saved { try await self.repository.setQuickLogUndo(saved) }
            HapticManager.success()
            scheduleFitnessSync(after:"quick food log")
        }
        if saved != nil {
            UsageMonitor.complete(usageRun, interactions: 1)
            return true
        }
        UsageMonitor.fail(usageRun, category: .unknown, interactions: 1)
        return false
    }

    func undoQuickLog() async {
        guard let entry=quickLogUndo else { return }
        await run {
            try await self.repository.deleteLog(entry)
            try await self.repository.clearQuickLogUndo(entryId:entry.id)
            try await self.reloadLocal()
            self.quickLogUndo=nil
            self.statusMessage="Quick log undone"
            HapticManager.selection()
            scheduleFitnessSync(after:"quick-log undo")
        }
    }

    func deleteLog(_ entry: FitnessFoodLogEntry) async -> Bool {
        await mutate(success: "Diary entry removed") {
            try await self.repository.deleteLog(entry)
            try await self.repository.clearQuickLogUndo(entryId:entry.id)
            if self.quickLogUndo?.id == entry.id { self.quickLogUndo=nil }
        }
    }

    func logPlannedMeal(_ draft:FitnessPlannedMealLogDraft) async -> Bool {
        let usageRun = UsageMonitor.start(.logPlannedMeal)
        do {
            try await withFitnessStore {
                try await service.queuePlannedMealLog(draft)
                let pending=await recoverableValue(
                    section:"Pending planned meals",userMessage:nil,
                    { try await self.service.pendingPlannedMealLogs() }
                )
                if let pending {
                    self.pendingPlannedMealLogs=pending
                }
                let logged=await recoverableValue(
                    section:"Logged planned meals",userMessage:nil,
                    { try await self.repository.loggedPlannedMealIds() }
                )
                if let logged {
                    self.loggedPlannedMealIds=logged
                }
                _=await recoverableValue(section:"Nutrition diary") {
                    try await self.reloadLocal()
                }
            }
            statusMessage="Added \(draft.recipeName) to \(draft.mealType.title)"
            UsageMonitor.complete(usageRun, interactions: 1)
            HapticManager.success()
            return true
        } catch {
            UsageMonitor.fail(usageRun, error: error, interactions: 1)
            errorMessage=error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func isPlannedMealAdded(_ meal:FitnessPlannedHouseholdMeal) -> Bool {
        loggedPlannedMealIds.contains(meal.mealPlanId)
            || pendingPlannedMealLogs.contains { $0.mealPlanId == meal.mealPlanId }
    }

    func loadHouseholdRecipeLinks(refresh:Bool=false) async {
        isLoading=true; errorMessage=nil
        defer { isLoading=false }
        do {
            try await withFitnessStore {
                async let meals=service.householdMeals()
                async let links=service.householdMealLinks(refresh:refresh)
                householdMeals=try await meals
                householdMealLinks=try await links
                try await reloadLocal()
            }
        } catch { errorMessage=error.localizedDescription }
    }

    func linkHouseholdMeal(_ meal:FitnessHouseholdMeal,to recipe:FitnessRecipe) async -> Bool {
        guard let version=recipe.currentVersion else { return false }
        do {
            let link=try await service.linkHouseholdMeal(
                mealId:meal.id,recipeVersionId:version.id
            )
            householdMealLinks.removeAll { $0.mealId == meal.id }
            householdMealLinks.append(link)
            statusMessage="\(meal.name) now uses \(recipe.name)"
            HapticManager.success(); return true
        } catch {
            errorMessage=error.localizedDescription; HapticManager.error(); return false
        }
    }

    func unlinkHouseholdMeal(_ meal:FitnessHouseholdMeal) async -> Bool {
        do {
            try await service.unlinkHouseholdMeal(mealId:meal.id)
            householdMealLinks.removeAll { $0.mealId == meal.id }
            statusMessage="Recipe link removed"
            HapticManager.selection(); return true
        } catch {
            errorMessage=error.localizedDescription; HapticManager.error(); return false
        }
    }

    func repeatEntries(_ entries: [FitnessFoodLogEntry],on date: Date,meal: FitnessMeal? = nil) async -> Bool {
        await mutate(success: "Repeated \(meal?.title ?? "day")") {
            _ = try await self.repository.repeatEntries(entries,on: date,meal: meal)
        }
    }

    func repeatYesterdayBreakfast() async -> Bool {
        await mutate(success: "Yesterday's breakfast repeated") {
            let yesterday = Calendar.current.date(byAdding: .day,value: -1,to: self.selectedDate) ?? self.selectedDate
            let source = try await self.repository.day(on: yesterday)
            _ = try await self.repository.repeatEntries(
                source.entries,on: self.selectedDate,meal: .breakfast
            )
        }
    }

    func createRecipe(_ draft: FitnessRecipeDraft) async -> Bool {
        await mutate(success: "Recipe saved") { _ = try await self.repository.createRecipe(draft) }
    }

    func copyRecipeToMine(_ recipe: FitnessRecipe) async -> Bool {
        guard let version = recipe.currentVersion else { return false }
        return await createRecipe(FitnessRecipeDraft(
            name: "\(recipe.name) copy",notes: recipe.notes,householdShared: false,favourite: false,
            components: version.components,finishedWeightG: version.finishedWeightG,
            servings: version.servings,caloriesKcal: version.nutrients.caloriesKcal,
            lowerCaloriesKcal: version.lowerCaloriesKcal,upperCaloriesKcal: version.upperCaloriesKcal,
            confidence: version.confidence,sourceNote: "Copied from household recipe \(recipe.name)"
        ))
    }

    func addRecipeVersion(recipeId: String,draft: FitnessRecipeDraft) async -> Bool {
        await mutate(success: "New recipe details saved") {
            _ = try await self.repository.addRecipeVersion(recipeId: recipeId,draft: draft)
        }
    }

    func saveRecipe(_ recipe: FitnessRecipe) async -> Bool {
        await mutate(success: "Recipe updated") { _ = try await self.repository.saveRecipeIdentity(recipe) }
    }

    func saveTemplate(_ template: FitnessMealTemplate,baseRevision: Int? = nil) async -> Bool {
        await mutate(success: "Meal template saved") {
            _ = try await self.repository.saveTemplate(template,baseRevision: baseRevision)
        }
    }

    func archiveTemplate(_ template: FitnessMealTemplate) async -> Bool {
        await mutate(success: "Meal template archived") { try await self.repository.archiveTemplate(template) }
    }

    /// `entryIds` maps each template item id to the diary entry it should
    /// become, so logging the same template twice by accident updates those
    /// entries instead of adding a second copy of every item.
    func logTemplate(
        _ template: FitnessMealTemplate,amounts: [String: Double],at date: Date,
        entryIds: [String: String] = [:]
    ) async -> Bool {
        let usageRun = UsageMonitor.start(.logMealTemplate)
        let succeeded = await mutate(success: "Template added as separate diary entries") {
            _ = try await self.repository.logTemplate(
                template,amounts: amounts,at: date,entryIds: entryIds
            )
        }
        if succeeded {
            UsageMonitor.complete(usageRun)
        } else {
            UsageMonitor.fail(usageRun, category: .unknown)
        }
        return succeeded
    }

    func saveTarget(_ target: FitnessNutritionTarget,baseRevision: Int? = nil) async -> Bool {
        await mutate(success: "Nutrition target saved") {
            _ = try await self.repository.saveTarget(target,baseRevision: baseRevision)
        }
    }

    func archiveTarget(_ target: FitnessNutritionTarget) async -> Bool {
        await mutate(success: "Nutrition target archived") { try await self.repository.archiveTarget(target) }
    }

    func rebucket(minutes: Int) async -> Bool {
        await mutate(success: nil) {
            let result = try await self.service.rebucket(
                dayStartMinutes: minutes,timezone: TimeZone.current.identifier
            )
            self.statusMessage = "\(result.affectedEntries ?? 0) diary entries checked and regrouped."
        }
    }

    func saveHeartRateZones(_ boundaries: [Int]) async -> Bool {
        await mutate(success: "Heart-rate zones saved") {
            self.settings = try await self.service.saveHeartRateZoneBoundaries(
                boundaries,settings: self.settings
            )
        }
    }

    func retryLabel(_ label: FitnessPendingNutritionLabel) async {
        do {
            labels = try await withFitnessStore {
                await service.retryLabel(assetId:label.id)
                return try await repository.pendingLabels()
            }
        } catch is CancellationError {
            return
        } catch {
            recordRecoverableFailure(
                section:"Nutrition-label retry",
                userMessage:"The label retry could not be started. Its protected photo was kept.",
                error:error
            )
        }
    }

    func cancelLabel(_ label: FitnessPendingNutritionLabel) async {
        await run {
            try await self.service.cancelLabel(label)
            self.labels = try await self.repository.pendingLabels()
        }
    }

    func mergePreview(sourceId: String,targetId: String) async throws -> FitnessFoodMergePreview {
        try await service.mergePreview(sourceId: sourceId,targetId: targetId)
    }

    func merge(sourceId: String,targetId: String) async -> Bool {
        await mutate(success: "Foods merged; existing diary history was retained") {
            _ = try await self.service.merge(sourceId: sourceId,targetId: targetId)
        }
    }

    func quickFoods(for meal: FitnessMeal) -> [FitnessFood] {
        foods.filter { food in
            food.active && food.currentVersion != nil && (
                food.isFavourite || food.quickUse?.recentMealKeys.contains(meal) == true
                    || (food.quickUse?.frequencyCount ?? 0) > 1
            )
        }.prefix(12).map { $0 }
    }

    func quickTemplates(for meal: FitnessMeal) -> [FitnessMealTemplate] {
        templates.filter { $0.active && ($0.meal == meal || $0.timeRelevance == meal.rawValue) }
    }

    func effectiveTarget(for metric: FitnessNutritionMetric) -> FitnessNutritionTarget? {
        targets.first { $0.active && $0.metric == metric }
    }

    private func mutate(success: String?,_ operation: () async throws -> Void) async -> Bool {
        var succeeded = false
        await run {
            try await operation()
            try await self.reloadLocal()
            self.statusMessage = success
            succeeded = true
            HapticManager.success()
            scheduleFitnessSync(after:"nutrition update")
        }
        return succeeded
    }

    private func reloadLocal() async throws {
        async let settings = repository.settings()
        async let foods = repository.foods(search: search,includeArchived: includeArchived)
        async let recipes = repository.recipes(includeArchived: includeArchived)
        async let templates = repository.mealTemplates(includeArchived: includeArchived)
        async let targets = repository.nutritionTargets(includeArchived: includeArchived)
        async let labels = repository.pendingLabels()
        async let day = repository.day(on: selectedDate)
        self.settings = try await settings
        self.foods = try await foods
        self.recipes = try await recipes
        self.templates = try await templates
        self.targets = try await targets
        self.labels = try await labels
        self.day = try await day
    }

    private func analysisRange() -> (start: String,end: String)? {
        guard !day.nutritionDate.isEmpty else { return nil }
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone = .current
        return FitnessCalculations.nutritionAnalysisRange(
            endingOn:day.nutritionDate,days:analysisPeriodDays,calendar:calendar
        )
    }

    private func quickAmount(
        food:FitnessFood,version:FitnessFoodVersion
    ) -> (entered:Double,enteredUnit:String,canonical:Double,canonicalUnit:String,quality:FitnessNutritionMeasurementQuality) {
        let quick=food.quickUse
        if let entered=quick?.usualAmount ?? quick?.lastAmount {
            let unit=quick?.usualAmount != nil ? (quick?.usualUnit ?? version.referenceUnit) : (quick?.lastUnit ?? version.referenceUnit)
            if unit == version.referenceUnit {
                return(entered,unit,entered,unit,.estimated)
            }
            if let serving=food.servings.filter(\.active).sorted(by:{ $0.isDefault && !$1.isDefault }).first(where:{ $0.unit == unit }),serving.amount > 0 {
                return(entered,unit,entered/serving.amount*serving.canonicalAmount,serving.canonicalUnit,serving.measurementQuality)
            }
        }
        if let serving=food.servings.first(where:{ $0.active && $0.isDefault }) {
            return(serving.amount,serving.unit,serving.canonicalAmount,serving.canonicalUnit,serving.measurementQuality)
        }
        return(version.referenceAmount,version.referenceUnit,version.referenceAmount,version.referenceUnit,.estimated)
    }

    private static func mealForCurrentTime(_ date:Date=Date()) -> FitnessMeal {
        switch Calendar.current.component(.hour,from:date) {
        case 4..<11:return .breakfast
        case 11..<15:return .lunch
        case 17..<22:return .dinner
        default:return .snack
        }
    }
}

extension FitnessFoodBarcodeLookup {
    var reviewDraft:FitnessFoodDraft {
        FitnessFoodDraft(
            name:name,brand:brand,categoryKey:nil,barcode:barcode,notes:nil,
            householdShared:false,favourite:false,
            version:FitnessFoodVersionDraft(
                referenceAmount:referenceAmount,referenceUnit:referenceUnit,
                caloriesKcal:nutrients.caloriesKcal,sourceEnergyValue:nil,sourceEnergyUnit:nil,
                proteinG:nutrients.proteinG,carbohydrateG:nutrients.carbohydrateG,
                sugarsG:nutrients.sugarsG,fatG:nutrients.fatG,
                saturatedFatG:nutrients.saturatedFatG,fibreG:nutrients.fibreG,
                saltG:nutrients.saltG,sodiumMg:nutrients.sodiumMg,micronutrients:nutrients.micronutrients,
                sourceType:"open_food_facts",sourceNote:sourceUrl,confidence:"copied"
            )
        )
    }
}

@MainActor
final class FitnessOnboardingViewModel: ObservableObject {
    @Published private(set) var profile:FitnessOnboardingProfile?
    @Published var draft:FitnessOnboardingDraft?
    @Published var preview:FitnessOnboardingWeekPreview?
    @Published var step=0
    @Published private(set) var isWorking=false
    @Published var actionError:String?

    private let service:FitnessNutritionService
    private var hasLoaded=false

    init(service:FitnessNutritionService = .shared) {
        self.service=service
    }

    var shouldPresent:Bool {
        FitnessOnboardingCommitPolicy.presentsAutomatically(status:profile?.status)
    }
    var canFinishLater:Bool {
        FitnessOnboardingCommitPolicy.offersFinishLater(status:profile?.status)
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded=true
        do {
            let value=try await service.onboardingProfile(refresh:true)
            profile=value
            draft=FitnessOnboardingDraft(profile:value,clientId:try APIClient.shared.clientId)
            preview=value.preview
        } catch {
            // First-run setup is additive. A failed background fetch must never
            // block the rest of Fitness or turn into persistent technical UI.
        }
    }

    func next() async {
        actionError=nil
        if step < 2 { await persistAndAdvance() }
        else { await makePreview() }
    }

    func back() {
        actionError=nil
        if preview != nil {
            preview=nil; step=2
        } else {
            step=max(0,step-1)
        }
        HapticManager.selection()
    }

    func makePreview() async {
        guard var draft else { return }
        isWorking=true; actionError=nil
        defer { isWorking=false }
        do {
            draft.clientId=try APIClient.shared.clientId
            draft.clientTimestamp=FitnessDatabase.dateString(Date())
            self.draft=draft
            let saved=try await service.saveOnboarding(draft)
            profile=saved
            preview=try await service.previewOnboardingWeek()
            step=3
            HapticManager.success()
        } catch {
            actionError=error.localizedDescription
            HapticManager.error()
        }
    }

    private func persistAndAdvance() async {
        guard var draft else { return }
        isWorking=true; actionError=nil
        defer { isWorking=false }
        do {
            draft.clientId=try APIClient.shared.clientId
            draft.clientTimestamp=FitnessDatabase.dateString(Date())
            self.draft=draft
            let saved=try await service.saveOnboarding(draft)
            profile=saved
            self.draft=FitnessOnboardingDraft(
                profile:saved,clientId:try APIClient.shared.clientId
            )
            step += 1
            HapticManager.selection()
        } catch {
            actionError=error.localizedDescription
            HapticManager.error()
        }
    }

    func confirm() async -> Bool {
        guard FitnessOnboardingCommitPolicy.canConfirm(preview:preview),let preview else { return false }
        isWorking=true; actionError=nil
        defer { isWorking=false }
        do {
            let result=try await service.confirmOnboarding(previewId:preview.previewId)
            if var current=profile {
                current.status = .complete
                current.preview = result.week
                current.confirmation = FitnessOnboardingConfirmation(
                    completedAt:result.completedAt,goalId:result.goalId,sessionIds:result.sessionIds
                )
                profile=current
            }
            HapticManager.success()
            return true
        } catch {
            actionError=error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func skip() async -> Bool {
        isWorking=true; actionError=nil
        defer { isWorking=false }
        do {
            profile=try await service.skipOnboarding()
            HapticManager.selection()
            return true
        } catch {
            actionError=error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func resumeSkippedSetup() async {
        guard canFinishLater,var draft else { return }
        isWorking=true; actionError=nil
        defer { isWorking=false }
        do {
            draft.clientId=try APIClient.shared.clientId
            draft.clientTimestamp=FitnessDatabase.dateString(Date())
            self.draft=draft
            profile=try await service.saveOnboarding(draft)
            preview=nil; step=0
            HapticManager.selection()
        } catch {
            actionError=error.localizedDescription
            HapticManager.error()
        }
    }
}
