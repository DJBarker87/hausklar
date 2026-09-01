import Foundation
import os

private let fitnessNutritionServiceLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessNutritionService"
)

enum FitnessNutritionServiceError: LocalizedError {
    case identityChanged
    case stagedLabelNeedsConnection
    case invalidHeartRateZones
    case invalidQuickEntryData

    var errorDescription: String? {
        switch self {
        case .identityChanged: "The active Fitness profile changed. Try again in the current profile."
        case .stagedLabelNeedsConnection: "Reconnect before cancelling this staged nutrition label."
        case .invalidHeartRateZones: "Enter four unique, increasing heart-rate boundaries between 60 and 240 bpm."
        case .invalidQuickEntryData: "Those quick-entry details could not be used. Refresh and try again."
        }
    }
}

actor FitnessNutritionService {
    static let shared = FitnessNutritionService()

    private let repository: FitnessNutritionRepository
    private let apiClient: APIClient
    private let database: FitnessDatabase
    private var identity: FitnessServiceSession?
    private var flushTask: Task<Void,Never>?
    private var plannedMealFlushTask: Task<Void,Never>?

    init(
        repository: FitnessNutritionRepository = .shared,
        apiClient: APIClient = .shared,
        database: FitnessDatabase = .shared
    ) {
        self.repository = repository
        self.apiClient = apiClient
        self.database = database
    }

    func activate(identity: String) async {
        if self.identity?.identity == identity, let session = self.identity {
            do {
                try database.validate(session.storeLease)
                return
            } catch {
                fitnessNutritionServiceLogger.error(
                    "Active Fitness nutrition lease became invalid: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        await suspend()
        do {
            let lease = try database.lease(for: identity)
            _ = try await database.withLease(lease) {
                try await repository.reconcilePrivateLabelFiles()
            }
            try database.validate(lease)
            self.identity = FitnessServiceSession(identity: identity, storeLease: lease)
        } catch {
            fitnessNutritionServiceLogger.error(
                "Fitness nutrition activation failed; private-label state was left untouched: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func suspend() async {
        identity = nil
        let pendingLabelFlush = flushTask
        let pendingMealFlush = plannedMealFlushTask
        flushTask = nil
        plannedMealFlushTask = nil
        pendingLabelFlush?.cancel()
        pendingMealFlush?.cancel()
        if let pendingLabelFlush { await pendingLabelFlush.value }
        if let pendingMealFlush { await pendingMealFlush.value }
    }

    func flushPendingLabels() async {
        guard let expectedIdentity = identity else { return }
        if let flushTask { await flushTask.value; return }
        let task = Task { [weak self, database] in
            guard let self else { return }
            do {
                try await database.withLease(expectedIdentity.storeLease) {
                    await self.performFlush(expectedIdentity: expectedIdentity)
                }
            } catch {
                // Teardown invalidated the lease; keep the previous owner's
                // protected label and outbox row for their next session.
                fitnessNutritionServiceLogger.error(
                    "Nutrition-label flush stopped with its queue retained: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        flushTask = task
        await task.value
        flushTask = nil
    }

    private func performFlush(expectedIdentity: FitnessServiceSession) async {
        do {
            try await repository.cleanupAcknowledgedLabels()
        } catch {
            fitnessNutritionServiceLogger.error(
                "Acknowledged nutrition-label cleanup was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        let pending: [FitnessPendingNutritionLabel]
        do {
            pending = try await repository.pendingLabels()
        } catch {
            fitnessNutritionServiceLogger.error(
                "Pending nutrition labels could not be read; no upload was attempted: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        for item in pending where !item.uploadAcknowledged && !item.referenceAcknowledged {
            guard !Task.isCancelled,identity == expectedIdentity else { return }
            do {
                let url = try await repository.localLabelURL(assetId: item.id)
                let result: FitnessPrivateAssetUploadResult = try await apiClient.uploadMultipart(
                    "/fitness/files/private",fileURL: url,filename: item.originalFilename,
                    mediaType: item.mediaType,
                    fields: ["asset_id": item.id,"asset_kind": "nutrition_label"]
                )
                guard identity == expectedIdentity else { return }
                try await repository.markLabelUploadAcknowledged(assetId: item.id,result: result)
            } catch {
                guard identity == expectedIdentity else { return }
                let uploadError = error
                do {
                    try await repository.markLabelFailure(
                        assetId:item.id,message:uploadError.localizedDescription
                    )
                } catch {
                    fitnessNutritionServiceLogger.fault(
                        "Nutrition-label flush stopped because failure state could not be saved; protected source retained. Asset: \(item.id, privacy: .private). Persistence error: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                if Self.isOffline(uploadError) { return }
            }
        }
    }

    func retryLabel(assetId: String) async {
        guard let expectedIdentity=identity else { return }
        do {
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.retryLabel(assetId: assetId)
            }
        } catch {
            fitnessNutritionServiceLogger.fault(
                "Nutrition-label retry stopped because retry state could not be saved; protected source retained. Asset: \(assetId, privacy: .private). Persistence error: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        await flushPendingLabels()
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            fitnessNutritionServiceLogger.error(
                "Immediate Fitness sync after nutrition-label retry was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func cancelLabel(_ label: FitnessPendingNutritionLabel) async throws {
        let expectedIdentity = try requireIdentity()
        if label.uploadAcknowledged && !label.referenceAcknowledged {
            do {
                try await apiClient.delete("/fitness/files/private/\(label.id)")
            } catch {
                if Self.isOffline(error) { throw FitnessNutritionServiceError.stagedLabelNeedsConnection }
                throw error
            }
            guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.finalizeAbandonedLabel(assetId: label.id)
            }
        } else if !label.uploadAcknowledged {
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.removePendingLabel(assetId: label.id)
            }
        }
    }

    func analysis(
        start: String,
        end: String,
        refresh: Bool = false
    ) async throws -> FitnessNutritionAnalysis {
        let expectedIdentity = try requireIdentity()
        let value: FitnessNutritionAnalysis = try await apiClient.get(
            "/fitness/nutrition/analysis",
            queryItems: [
                URLQueryItem(name: "start", value: start),
                URLQueryItem(name: "end", value: end),
            ],
            bypassCache: refresh
        )
        guard identity == expectedIdentity else {
            throw FitnessNutritionServiceError.identityChanged
        }
        return value
    }

    func barcodeLookup(_ barcode: String) async throws -> FitnessFoodBarcodeLookup {
        let expectedIdentity=try requireIdentity()
        let value:FitnessFoodBarcodeLookup=try await apiClient.get(
            "/fitness/food-lookup/barcode/\(barcode)",bypassCache:true
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        return value
    }

    func foodSearch(_ query: String) async throws -> [FitnessFoodBarcodeLookup] {
        let expectedIdentity = try requireIdentity()
        let value: [FitnessFoodBarcodeLookup] = try await apiClient.get(
            "/fitness/food-lookup/search",
            queryItems: [URLQueryItem(name: "q", value: query)],
            bypassCache: true
        )
        guard identity == expectedIdentity else {
            throw FitnessNutritionServiceError.identityChanged
        }
        return value
    }

    // MARK: First run

    func workspacePreference(refresh: Bool = false) async throws -> FitnessWorkspacePreference {
        let expectedIdentity = try requireIdentity()
        let value: FitnessWorkspacePreference = try await apiClient.get(
            "/fitness/workspace", bypassCache: refresh
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        return value
    }

    func updateWorkspacePreference(
        enabled: Bool? = nil,
        pinned: Bool? = nil,
        showNutritionToday: Bool? = nil
    ) async throws -> FitnessWorkspacePreference {
        let expectedIdentity = try requireIdentity()
        let value: FitnessWorkspacePreference = try await apiClient.patch(
            "/fitness/workspace",
            body: FitnessWorkspacePreferenceUpdate(
                enabled: enabled,
                pinned: pinned,
                showNutritionToday: showNutritionToday
            )
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        return value
    }

    // MARK: Today quick entry

    func mealCompletions(on date: String) async throws -> [FitnessNutritionMealCompletion] {
        guard Self.isDateOnly(date) else {
            throw FitnessNutritionServiceError.invalidQuickEntryData
        }
        let expectedIdentity = try requireIdentity()
        do {
            let value: [FitnessNutritionMealCompletion] = try await apiClient.get(
                "/fitness/nutrition/meal-completions",
                queryItems: [URLQueryItem(name: "date", value: date)],
                bypassCache: true
            )
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheMealCompletions(value, date: date)
            }
            return value
        } catch {
            let requestError = error
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            if let cached = try await database.withLease(
                expectedIdentity.storeLease,
                operation: { try await repository.cachedMealCompletions(date: date) }
            ) {
                return cached
            }
            throw requestError
        }
    }

    func completeMeal(on date: String, meal: FitnessMeal) async throws -> FitnessNutritionMealCompletion {
        guard Self.isDateOnly(date), [.breakfast, .lunch, .dinner, .snack].contains(meal) else {
            throw FitnessNutritionServiceError.invalidQuickEntryData
        }
        let expectedIdentity = try requireIdentity()
        let request = FitnessMealCompletionRequest(
            id: UUID().uuidString.lowercased(),
            nutritionDate: date,
            meal: meal,
            clientId: try apiClient.clientId,
            clientTimestamp: FitnessDatabase.dateString(Date())
        )
        let value: FitnessNutritionMealCompletion = try await apiClient.post(
            "/fitness/nutrition/meal-completions",
            body: request,
            operationID: request.id
        )
        guard identity == expectedIdentity else {
            throw FitnessNutritionServiceError.identityChanged
        }
        try await database.withLease(expectedIdentity.storeLease) {
            var cached = try await repository.cachedMealCompletions(date: date) ?? []
            cached.removeAll { $0.meal == meal }
            cached.append(value)
            try await repository.cacheMealCompletions(cached, date: date)
        }
        return value
    }

    func quickEntryPreferences(
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<FitnessQuickEntryPreferences> {
        let expectedIdentity = try requireIdentity()
        do {
            let value: FitnessQuickEntryPreferences = try await apiClient.get(
                "/fitness/quick-entry-preferences",
                bypassCache: refresh
            )
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            guard value.mealTimes.allValid else {
                throw FitnessNutritionServiceError.invalidQuickEntryData
            }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheQuickEntryPreferences(value)
            }
            return FitnessLoadResult(value: value, isFromCache: false)
        } catch {
            let requestError = error
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            if let cached = try await database.withLease(
                expectedIdentity.storeLease,
                operation: { try await repository.cachedQuickEntryPreferences() }
            ), cached.mealTimes.allValid {
                return FitnessLoadResult(value: cached, isFromCache: true)
            }
            throw requestError
        }
    }

    func updateQuickEntryPreferences(
        _ mealTimes: FitnessQuickEntryMealTimes
    ) async throws -> FitnessQuickEntryPreferences {
        guard mealTimes.allValid else {
            throw FitnessNutritionServiceError.invalidQuickEntryData
        }
        let expectedIdentity = try requireIdentity()
        let value: FitnessQuickEntryPreferences = try await apiClient.patch(
            "/fitness/quick-entry-preferences",
            body: FitnessQuickEntryPreferencesUpdate(mealTimes: mealTimes)
        )
        guard identity == expectedIdentity else {
            throw FitnessNutritionServiceError.identityChanged
        }
        guard value.mealTimes.allValid else {
            throw FitnessNutritionServiceError.invalidQuickEntryData
        }
        try await database.withLease(expectedIdentity.storeLease) {
            try await repository.cacheQuickEntryPreferences(value)
        }
        return value
    }

    func strengthAvailability(
        start: String,
        end: String,
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<FitnessStrengthAvailability> {
        guard Self.isDateOnly(start), Self.isDateOnly(end), start <= end else {
            throw FitnessNutritionServiceError.invalidQuickEntryData
        }
        let expectedIdentity = try requireIdentity()
        do {
            let value: FitnessStrengthAvailability = try await apiClient.get(
                "/fitness/strength-availability",
                queryItems: [
                    URLQueryItem(name: "start", value: start),
                    URLQueryItem(name: "end", value: end),
                ],
                bypassCache: refresh
            )
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheStrengthAvailability(
                    value,
                    start: start,
                    end: end
                )
            }
            return FitnessLoadResult(value: value, isFromCache: false)
        } catch {
            let requestError = error
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            if let cached = try await database.withLease(
                expectedIdentity.storeLease,
                operation: {
                    try await repository.cachedStrengthAvailability(
                        start: start,
                        end: end
                    )
                }
            ) {
                return FitnessLoadResult(value: cached, isFromCache: true)
            }
            throw requestError
        }
    }

    func viSchedule(
        start: String,
        end: String,
        refresh: Bool = false
    ) async throws -> FitnessLoadResult<FitnessViSchedule> {
        guard Self.isDateOnly(start), Self.isDateOnly(end), start <= end else {
            throw FitnessNutritionServiceError.invalidQuickEntryData
        }
        let expectedIdentity = try requireIdentity()
        do {
            let value: FitnessViSchedule = try await apiClient.get(
                "/fitness/vi-schedule",
                queryItems: [
                    URLQueryItem(name: "start", value: start),
                    URLQueryItem(name: "end", value: end),
                ],
                bypassCache: refresh
            )
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheViSchedule(value, start: start, end: end)
            }
            return FitnessLoadResult(value: value, isFromCache: false)
        } catch {
            let requestError = error
            guard identity == expectedIdentity else {
                throw FitnessNutritionServiceError.identityChanged
            }
            if let cached = try await database.withLease(
                expectedIdentity.storeLease,
                operation: {
                    try await repository.cachedViSchedule(start: start, end: end)
                }
            ) {
                return FitnessLoadResult(value: cached, isFromCache: true)
            }
            throw requestError
        }
    }

    func onboardingProfile(refresh: Bool = false) async throws -> FitnessOnboardingProfile {
        let expectedIdentity=try requireIdentity()
        do {
            let value:FitnessOnboardingProfile=try await apiClient.get(
                "/fitness/onboarding",bypassCache:refresh
            )
            guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheOnboarding(value)
            }
            return value
        } catch {
            let requestError = error
            guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
            do {
                if let cached = try await database.withLease(
                    expectedIdentity.storeLease,
                    operation:{ try await repository.cachedOnboarding() }
                ) {
                    return cached
                }
            } catch {
                fitnessNutritionServiceLogger.error(
                    "Fitness onboarding cache could not be read: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            throw requestError
        }
    }

    func saveOnboarding(_ draft:FitnessOnboardingDraft) async throws -> FitnessOnboardingProfile {
        let expectedIdentity=try requireIdentity()
        let value:FitnessOnboardingProfile=try await apiClient.put(
            "/fitness/onboarding",body:draft
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await repository.cacheOnboarding(value)
        }
        return value
    }

    func skipOnboarding() async throws -> FitnessOnboardingProfile {
        let expectedIdentity=try requireIdentity()
        let value:FitnessOnboardingProfile=try await apiClient.post("/fitness/onboarding/skip")
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await repository.cacheOnboarding(value)
        }
        return value
    }

    func previewOnboardingWeek(weekStart:String? = nil) async throws -> FitnessOnboardingWeekPreview {
        let expectedIdentity=try requireIdentity()
        let value:FitnessOnboardingWeekPreview=try await apiClient.post(
            "/fitness/onboarding/preview-week",body:FitnessOnboardingPreviewRequest(weekStart:weekStart)
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        return value
    }

    func confirmOnboarding(previewId:String) async throws -> FitnessOnboardingConfirmResponse {
        let expectedIdentity=try requireIdentity()
        let value:FitnessOnboardingConfirmResponse=try await apiClient.post(
            "/fitness/onboarding/confirm",body:FitnessOnboardingConfirmRequest(previewId:previewId)
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            if var profile=try await repository.cachedOnboarding() {
                profile.status = .complete
                profile.preview = value.week
                profile.confirmation = FitnessOnboardingConfirmation(
                    completedAt:value.completedAt,goalId:value.goalId,sessionIds:value.sessionIds
                )
                try await repository.cacheOnboarding(profile)
            }
        }
        return value
    }

    // MARK: Household meal bridge

    func plannedMeals(on date:String,refresh:Bool = false) async throws -> [FitnessPlannedHouseholdMeal] {
        let expectedIdentity=try requireIdentity()
        await flushPendingPlannedMeals()
        do {
            let value:[FitnessPlannedHouseholdMeal]=try await apiClient.get(
                "/fitness/planned-meals",
                queryItems:[URLQueryItem(name:"date",value:date)],
                bypassCache:refresh
            )
            guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cachePlannedMeals(value,date:date)
            }
            return value
        } catch {
            let requestError = error
            guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
            do {
                let cached = try await database.withLease(
                    expectedIdentity.storeLease,
                    operation:{ try await repository.cachedPlannedMeals(date:date) }
                )
                if !cached.isEmpty { return cached }
            } catch {
                fitnessNutritionServiceLogger.error(
                    "Planned-meal cache could not be read: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            throw requestError
        }
    }

    func householdMeals() async throws -> [FitnessHouseholdMeal] {
        let expectedIdentity=try requireIdentity()
        let value:[FitnessHouseholdMeal]=try await apiClient.get("/meals/")
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        return value
    }

    func householdMealLinks(refresh:Bool = false) async throws -> [FitnessHouseholdMealLink] {
        let expectedIdentity=try requireIdentity()
        do {
            let value:[FitnessHouseholdMealLink]=try await apiClient.get(
                "/fitness/household-meals",bypassCache:refresh
            )
            guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
            try await database.withLease(expectedIdentity.storeLease) {
                try await repository.cacheHouseholdMealLinks(value)
            }
            return value
        } catch {
            let requestError = error
            guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
            do {
                let cached = try await database.withLease(
                    expectedIdentity.storeLease,
                    operation:{ try await repository.cachedHouseholdMealLinks() }
                )
                if !cached.isEmpty { return cached }
            } catch {
                fitnessNutritionServiceLogger.error(
                    "Household-meal link cache could not be read: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
            throw requestError
        }
    }

    func linkHouseholdMeal(mealId:String,recipeVersionId:String) async throws -> FitnessHouseholdMealLink {
        let expectedIdentity=try requireIdentity()
        let value:FitnessHouseholdMealLink=try await apiClient.put(
            "/fitness/household-meals/\(mealId)",
            body:FitnessHouseholdMealLinkRequest(
                id:UUID().uuidString,recipeVersionId:recipeVersionId,
                clientId:try apiClient.clientId,clientTimestamp:FitnessDatabase.dateString(Date())
            )
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            var links = try await repository.cachedHouseholdMealLinks()
            links.removeAll { $0.mealId == mealId }
            links.append(value)
            try await repository.cacheHouseholdMealLinks(links)
        }
        return value
    }

    func unlinkHouseholdMeal(mealId:String) async throws {
        let expectedIdentity=try requireIdentity()
        try await apiClient.delete("/fitness/household-meals/\(mealId)")
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            var links = try await repository.cachedHouseholdMealLinks()
            links.removeAll { $0.mealId == mealId }
            try await repository.cacheHouseholdMealLinks(links)
        }
    }

    func queuePlannedMealLog(_ draft:FitnessPlannedMealLogDraft) async throws {
        let expectedIdentity=try requireIdentity()
        try await database.withLease(expectedIdentity.storeLease) {
            try await repository.enqueuePlannedMealLog(draft)
        }
        await flushPendingPlannedMeals()
    }

    func pendingPlannedMealLogs() async throws -> [FitnessPlannedMealLogDraft] {
        let expectedIdentity=try requireIdentity()
        return try await database.withLease(expectedIdentity.storeLease) {
            try await repository.pendingPlannedMealLogs()
        }
    }

    func flushPendingPlannedMeals() async {
        guard let expectedIdentity=identity else { return }
        if let plannedMealFlushTask { await plannedMealFlushTask.value; return }
        let task=Task { [weak self,database] in
            guard let self else { return }
            do {
                try await database.withLease(expectedIdentity.storeLease) {
                    let pending: [FitnessPlannedMealLogDraft]
                    do {
                        pending = try await self.repository.pendingPlannedMealLogs()
                    } catch {
                        fitnessNutritionServiceLogger.error(
                            "Planned-meal outbox could not be read; no log was sent: \(error.localizedDescription, privacy: .public)"
                        )
                        return
                    }
                    for draft in pending {
                        guard !Task.isCancelled,await self.identity == expectedIdentity else { return }
                        do {
                            let _:FitnessPrivatePlannedMealLog=try await self.apiClient.post(
                                "/fitness/planned-meals/\(draft.mealPlanId)/log",
                                body:FitnessPlannedMealLogRequest(draft:draft)
                            )
                            guard await self.identity == expectedIdentity else { return }
                            try await self.repository.acknowledgePlannedMealLog(
                                id:draft.id,mealPlanId:draft.mealPlanId
                            )
                            do {
                                try await FitnessSyncService.shared.syncNow()
                            } catch {
                                fitnessNutritionServiceLogger.error(
                                    "Immediate Fitness sync after planned-meal acknowledgement was deferred: \(error.localizedDescription, privacy: .public)"
                                )
                            }
                        } catch {
                            guard await self.identity == expectedIdentity else { return }
                            let logError = error
                            do {
                                try await self.repository.markPlannedMealAttempt(
                                    id:draft.id,error:logError.localizedDescription
                                )
                            } catch {
                                fitnessNutritionServiceLogger.fault(
                                    "Planned-meal flush stopped because attempt state could not be saved; outbox retained. Draft: \(draft.id, privacy: .private). Persistence error: \(error.localizedDescription, privacy: .public)"
                                )
                                return
                            }
                            if Self.isOffline(logError) { return }
                        }
                    }
                }
            } catch {
                // A store switch leaves every unsent meal in the old owner store.
                fitnessNutritionServiceLogger.error(
                    "Planned-meal flush stopped with its outbox retained: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        plannedMealFlushTask=task
        await task.value
        plannedMealFlushTask=nil
    }

    func rebucket(dayStartMinutes: Int,timezone: String) async throws -> FitnessNutritionRebucketResult {
        let expectedIdentity = try requireIdentity()
        let result: FitnessNutritionRebucketResult = try await apiClient.post(
            "/fitness/nutrition/settings/rebucket",
            body: NutritionRebucketRequest(
                nutritionDayStartMinutes: min(max(dayStartMinutes,0),480),timezone: timezone
            )
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await repository.applyRebucketResult(
                minutes: result.nutritionDayStartMinutes,timezone: timezone
            )
        }
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            fitnessNutritionServiceLogger.error(
                "Immediate Fitness sync after nutrition rebucketing was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        return result
    }

    func saveHeartRateZoneBoundaries(
        _ boundaries: [Int],
        settings: FitnessNutritionSettings
    ) async throws -> FitnessNutritionSettings {
        guard boundaries.count == 4,
              boundaries == boundaries.sorted(),
              Set(boundaries).count == boundaries.count,
              boundaries.allSatisfy({ 60...240 ~= $0 }) else {
            throw FitnessNutritionServiceError.invalidHeartRateZones
        }
        let expectedIdentity = try requireIdentity()
        let value: FitnessNutritionSettings = try await apiClient.patch(
            "/fitness/nutrition/settings",
            body: NutritionSettingsRequest(
                nutritionDayStartMinutes: settings.nutritionDayStartMinutes,
                timezone: settings.timezone,
                heartRateZoneBoundariesBpm: boundaries
            )
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        try await database.withLease(expectedIdentity.storeLease) {
            try await repository.applySettings(value)
        }
        return value
    }

    func mergePreview(sourceId: String,targetId: String) async throws -> FitnessFoodMergePreview {
        let expectedIdentity = try requireIdentity()
        let value: FitnessFoodMergePreview = try await apiClient.post(
            "/fitness/foods/merge/preview",body: FitnessFoodMergeRequest(sourceId: sourceId,targetId: targetId)
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        return value
    }

    func merge(sourceId: String,targetId: String) async throws -> FitnessFoodMergePreview {
        let expectedIdentity = try requireIdentity()
        let value: FitnessFoodMergePreview = try await apiClient.post(
            "/fitness/foods/merge",body: FitnessFoodMergeRequest(sourceId: sourceId,targetId: targetId)
        )
        guard identity == expectedIdentity else { throw FitnessNutritionServiceError.identityChanged }
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            fitnessNutritionServiceLogger.error(
                "Immediate Fitness sync after food merge was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        return value
    }

    private func requireIdentity() throws -> FitnessServiceSession {
        guard let identity else { throw FitnessNutritionServiceError.identityChanged }
        return identity
    }

    private static func isOffline(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return false }
        if case .networkError = api { return true }
        return false
    }

    private static func isDateOnly(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
        return bytes.enumerated().allSatisfy { index, byte in
            index == 4 || index == 7 || (48...57).contains(byte)
        }
    }
}

private struct NutritionRebucketRequest: Encodable {
    let nutritionDayStartMinutes: Int
    let timezone: String
}

private struct NutritionSettingsRequest: Encodable {
    let nutritionDayStartMinutes: Int
    let timezone: String
    let heartRateZoneBoundariesBpm: [Int]
}

private struct FitnessFoodMergeRequest: Encodable {
    let sourceId: String
    let targetId: String
}

private struct FitnessMealCompletionRequest: Encodable {
    let id: String
    let nutritionDate: String
    let meal: FitnessMeal
    let clientId: String
    let clientTimestamp: String

    private enum CodingKeys: String, CodingKey {
        case id, nutritionDate
        case meal = "mealKey"
        case clientId, clientTimestamp
    }
}

private struct FitnessOnboardingPreviewRequest: Encodable {
    let weekStart: String?
}

private struct FitnessOnboardingConfirmRequest: Encodable {
    let previewId: String
}

private struct FitnessHouseholdMealLinkRequest: Encodable {
    let id: String
    let recipeVersionId: String
    let clientId: String
    let clientTimestamp: String
}

private struct FitnessPlannedMealLogRequest: Encodable {
    let id: String
    let portion: Double
    let unit: FitnessPlannedMealUnit
    let loggedAtUtc: String
    let localTimezone: String
    let notes: String?
    let clientId: String?
    let clientTimestamp: String?

    init(draft:FitnessPlannedMealLogDraft) {
        id=draft.id; portion=draft.portion; unit=draft.unit
        loggedAtUtc=draft.loggedAtUtc; localTimezone=draft.localTimezone
        notes=draft.notes; clientId=draft.clientId; clientTimestamp=draft.clientTimestamp
    }
}
