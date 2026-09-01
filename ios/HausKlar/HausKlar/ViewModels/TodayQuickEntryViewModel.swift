import Foundation
import os

@MainActor
final class TodayQuickEntryViewModel: ObservableObject {
    @Published private(set) var preferences = FitnessQuickEntryPreferences.defaults
    @Published private(set) var mealPrompt: FitnessTodayMealPrompt?
    @Published private(set) var yesterdayEntries: [FitnessFoodLogEntry] = []
    @Published private(set) var completedMeals: Set<FitnessMeal> = []
    @Published private(set) var strengthAvailability: FitnessStrengthAvailability?
    @Published private(set) var viSchedule: FitnessViSchedule?
    @Published private(set) var preferencesAreCached = false
    @Published private(set) var preferencesUseDefaults = false
    @Published private(set) var availabilityIsCached = false
    @Published private(set) var viScheduleIsCached = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingAvailability = false
    @Published private(set) var isLoadingViSchedule = false
    @Published private(set) var busyAction: String?
    @Published private(set) var bookingWindowID: String?
    @Published var notice: String?
    @Published var errorMessage: String?

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "TodayQuickEntry"
    )

    private let nutritionService: FitnessNutritionService
    private let nutritionRepository: FitnessNutritionRepository
    private let fitnessRepository: FitnessRepository
    private let database: FitnessDatabase
    private let apiClient: APIClient
    private let now: () -> Date
    private var pendingViBooking: (
        id: String,
        fingerprint: String,
        timestamp: String
    )?

    init(
        nutritionService: FitnessNutritionService = .shared,
        nutritionRepository: FitnessNutritionRepository = .shared,
        fitnessRepository: FitnessRepository = .shared,
        database: FitnessDatabase = .shared,
        apiClient: APIClient = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.nutritionService = nutritionService
        self.nutritionRepository = nutritionRepository
        self.fitnessRepository = fitnessRepository
        self.database = database
        self.apiClient = apiClient
        self.now = now
    }

    func load(refresh: Bool = false) async {
        guard let identity = database.activeIdentity else {
            clearPrivateState()
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let lease = try database.lease(for: identity)
            let reference = now()
            async let preferenceResult = nutritionService.quickEntryPreferences(
                refresh: refresh
            )
            async let diaryResult = database.withLease(lease) {
                try await self.loadDiaryContext(at: reference)
            }
            async let completionResult = loadCompletedMeals(at: reference)
            do {
                let loaded = try await preferenceResult
                guard database.activeIdentity == identity else { return }
                preferences = loaded.value
                preferencesAreCached = loaded.isFromCache
                preferencesUseDefaults = false
            } catch {
                // Defaults are useful for a first offline launch, but are never
                // described as the adult's saved preference.
                Self.logger.error(
                    "Quick-entry preferences unavailable: \(error.localizedDescription, privacy: .private)"
                )
                preferences = .defaults
                preferencesAreCached = true
                preferencesUseDefaults = true
            }
            let diary = try await diaryResult
            let completions = await completionResult
            guard database.activeIdentity == identity else { return }
            updateDiary(
                diary.today,
                yesterday: diary.yesterday,
                completed: completions
            )
            // The two timetable providers are independent. Starting them
            // together preserves both results while avoiding serial latency on
            // every Today refresh.
            async let strength: Void = loadStrengthAvailability(
                for: reference,
                refresh: refresh
            )
            async let vi: Void = loadViSchedule(
                for: reference,
                refresh: refresh
            )
            _ = await (strength, vi)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Quick Fitness actions could not be loaded. Try again."
            HapticManager.error()
        }
    }

    func refreshMealContext() async {
        guard let identity = database.activeIdentity else {
            clearPrivateState()
            return
        }
        do {
            let lease = try database.lease(for: identity)
            let reference = now()
            let diary = try await database.withLease(lease) {
                try await self.loadDiaryContext(at: reference)
            }
            let completions = await loadCompletedMeals(at: reference)
            guard database.activeIdentity == identity else { return }
            updateDiary(
                diary.today,
                yesterday: diary.yesterday,
                completed: completions
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "Nutrition choices could not be refreshed."
        }
    }

    func repeatYesterdayMeal() async -> Bool {
        guard let prompt = mealPrompt, !yesterdayEntries.isEmpty,
              let identity = database.activeIdentity,
              busyAction == nil else { return false }
        busyAction = "repeat-meal"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let lease = try database.lease(for: identity)
            try await database.withLease(lease) {
                _ = try await self.nutritionRepository.repeatEntries(
                    self.yesterdayEntries,
                    on: self.now(),
                    meal: prompt.meal
                )
            }
            guard database.activeIdentity == identity else { return false }
            notice = "Yesterday’s \(prompt.meal.title.lowercased()) added."
            HapticManager.success()
            mealPrompt = FitnessTodayMealPrompt(
                meal: prompt.meal,
                trigger: prompt.trigger,
                hasEntries: true
            )
            Task { await syncFitness(after: "Today meal repeat") }
            return true
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func completeMeal(_ meal: FitnessMeal) async -> Bool {
        guard let identity = database.activeIdentity, busyAction == nil else { return false }
        busyAction = "complete-meal"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let date = Self.dateOnly(now())
            _ = try await nutritionService.completeMeal(on: date, meal: meal)
            guard database.activeIdentity == identity else { return false }
            completedMeals.insert(meal)
            if mealPrompt?.meal == meal { mealPrompt = nil }
            notice = "\(meal.title) completed."
            HapticManager.success()
            return true
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func loadStrengthAvailability(for date: Date, refresh: Bool = false) async {
        let day = Self.dateOnly(date)
        isLoadingAvailability = true
        defer { isLoadingAvailability = false }
        do {
            let result = try await nutritionService.strengthAvailability(
                start: day,
                end: day,
                refresh: refresh
            )
            strengthAvailability = result.value
            availabilityIsCached = result.isFromCache
        } catch is CancellationError {
            return
        } catch {
            strengthAvailability = nil
            availabilityIsCached = false
            // A timetable failure never blocks the manually selected start.
            Self.logger.error(
                "Strength availability unavailable: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func loadViSchedule(for date: Date, refresh: Bool = false) async {
        let day = Self.dateOnly(date)
        isLoadingViSchedule = true
        defer { isLoadingViSchedule = false }
        do {
            let result = try await nutritionService.viSchedule(
                start: day,
                end: day,
                refresh: refresh
            )
            viSchedule = result.value
            viScheduleIsCached = result.isFromCache
        } catch is CancellationError {
            return
        } catch {
            viSchedule = nil
            viScheduleIsCached = false
            Self.logger.error(
                "Vi schedule unavailable: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func addExercise(kind: FitnessTodayExerciseKind, start: Date) async -> Bool {
        guard let identity = database.activeIdentity, busyAction == nil else { return false }
        busyAction = "exercise"
        errorMessage = nil
        defer { busyAction = nil }
        do {
            let lease = try database.lease(for: identity)
            try await database.withLease(lease) {
                _ = try await self.fitnessRepository.createQuickPlannedSession(
                    sportKey: kind.sportKey,
                    title: kind.title,
                    scheduledStart: start,
                    expectedDurationSeconds: nil,
                    expectedDistanceMetres: nil,
                    expectedPaceSecondsPerKilometre: nil,
                    status: "accepted",
                    movable: false,
                    programmeId: nil,
                    primaryGoalId: nil
                )
            }
            guard database.activeIdentity == identity else { return false }
            notice = "\(kind.title) added for \(start.formatted(date: .omitted, time: .shortened))."
            HapticManager.success()
            Task { await syncFitness(after: "Today exercise") }
            return true
        } catch {
            errorMessage = error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func bookViClass(
        day: FitnessViScheduleDay,
        entry: FitnessViClass,
        online: Bool = true
    ) async -> Bool {
        guard online else {
            errorMessage = "Reconnect to confirm this Vi booking in HausKlar."
            HapticManager.error()
            return false
        }
        guard viSchedule?.relevant == true,
              viSchedule?.provider == "vi_training",
              busyAction == nil else { return false }
        let fingerprint = [
            day.date,
            entry.start,
            entry.end,
            entry.label,
            entry.classification.rawValue,
        ].joined(separator: "|")
        let operation: (id: String, fingerprint: String, timestamp: String)
        if let pendingViBooking,
           pendingViBooking.fingerprint == fingerprint {
            operation = pendingViBooking
        } else {
            operation = (
                UUID().uuidString.lowercased(),
                fingerprint,
                ISODateParser.stringNoFractional(from: now())
            )
            pendingViBooking = operation
        }
        busyAction = "vi-booking"
        bookingWindowID = entry.id
        errorMessage = nil
        defer {
            busyAction = nil
            bookingWindowID = nil
        }
        do {
            let response: FitnessViBookingResponse = try await apiClient.post(
                "/fitness/vi-bookings",
                body: FitnessViBookingRequest(
                    id: operation.id,
                    date: day.date,
                    start: entry.start,
                    end: entry.end,
                    label: entry.label,
                    classification: entry.classification,
                    provider: "vi_training",
                    clientId: try apiClient.clientId,
                    clientTimestamp: operation.timestamp
                ),
                operationID: operation.id
            )
            guard response.status == "booked",
                  !response.eventId.isEmpty,
                  response.classification == entry.classification else {
                errorMessage = "That Vi class could not be added to the calendar."
                HapticManager.error()
                return false
            }
            pendingViBooking = nil
            notice = "\(response.title) added to the family calendar."
            NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            HapticManager.success()
            return true
        } catch let error as APIError {
            if case .networkError = error {
                errorMessage = "Reconnect to confirm this Vi booking in HausKlar."
            } else {
                errorMessage = error.errorDescription
            }
        } catch let error as ClientIdentityError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That Vi class could not be added. Try again."
        }
        HapticManager.error()
        return false
    }

    func entriesForYesterdayPrompt() -> [FitnessFoodLogEntry] {
        yesterdayEntries
    }

    private func loadDiaryContext(
        at reference: Date
    ) async throws -> (today: FitnessNutritionDay, yesterday: FitnessNutritionDay) {
        let today = try await nutritionRepository.day(on: reference)
        let yesterdayDate = Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: reference
        ) ?? reference
        let yesterday = try await nutritionRepository.day(on: yesterdayDate)
        return (today, yesterday)
    }

    private func updateDiary(
        _ today: FitnessNutritionDay,
        yesterday: FitnessNutritionDay,
        completed: Set<FitnessMeal>
    ) {
        completedMeals = completed
        let prompt = FitnessQuickEntryPolicy.mealPrompt(
            at: now(),
            preferences: preferences,
            loggedMeals: Set(today.entries.map(\.meal)),
            completedMeals: completed
        )
        mealPrompt = prompt
        yesterdayEntries = prompt.map { selected in
            yesterday.entries.filter { $0.meal == selected.meal }
        } ?? []
    }

    private func loadCompletedMeals(at reference: Date) async -> Set<FitnessMeal> {
        do {
            let values = try await nutritionService.mealCompletions(
                on: Self.dateOnly(reference)
            )
            return Set(values.map(\.meal))
        } catch {
            Self.logger.error(
                "Meal completions unavailable: \(error.localizedDescription, privacy: .private)"
            )
            return completedMeals
        }
    }

    private func syncFitness(after context: String) async {
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error(
                "Fitness sync after \(context, privacy: .public) deferred: \(error.localizedDescription, privacy: .private)"
            )
            if notice != nil {
                notice = "Saved on this iPhone. Fitness will sync automatically."
            }
        }
    }

    private func clearPrivateState() {
        mealPrompt = nil
        yesterdayEntries = []
        completedMeals = []
        strengthAvailability = nil
        viSchedule = nil
        errorMessage = nil
        notice = nil
        preferencesUseDefaults = false
        viScheduleIsCached = false
    }

    private static func dateOnly(_ date: Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }
}

private struct FitnessViBookingRequest: Encodable {
    let id: String
    let date: String
    let start: String
    let end: String
    let label: String
    let classification: FitnessViClassClassification
    let provider: String
    let clientId: String
    let clientTimestamp: String
}

enum FitnessTodayExerciseKind: String, CaseIterable, Identifiable, Sendable {
    case run
    case strength

    var id: String { rawValue }
    var sportKey: String { self == .run ? "running" : "strength" }
    var title: String { self == .run ? "Run" : "Strength" }
    var symbol: String { self == .run ? "figure.run" : "dumbbell.fill" }
}

@MainActor
final class FitnessQuickEntrySettingsViewModel: ObservableObject {
    @Published private(set) var mealTimes = FitnessQuickEntryMealTimes.defaults
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isFromCache = false
    @Published private(set) var usesDefaults = false
    @Published var message: String?
    @Published var errorMessage: String?

    private let service: FitnessNutritionService

    init(service: FitnessNutritionService = .shared) {
        self.service = service
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await service.quickEntryPreferences(refresh: true)
            mealTimes = result.value.mealTimes
            isFromCache = result.isFromCache
            usesDefaults = false
        } catch {
            errorMessage = "Meal times could not be loaded. The defaults are shown."
            mealTimes = .defaults
            isFromCache = false
            usesDefaults = true
        }
    }

    @discardableResult
    func save(_ value: FitnessQuickEntryMealTimes) async -> Bool {
        guard value.allValid, !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        message = nil
        defer { isSaving = false }
        do {
            let saved = try await service.updateQuickEntryPreferences(value)
            mealTimes = saved.mealTimes
            isFromCache = false
            usesDefaults = false
            message = "Meal times saved."
            HapticManager.success()
            return true
        } catch {
            errorMessage = "Meal times could not be saved. Try again when connected."
            HapticManager.error()
            return false
        }
    }
}
