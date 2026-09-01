import Foundation

enum FitnessContract {
    static let syncProtocolVersion = 1
    static let clientSchemaVersion = 1
    static let payloadSchemaVersion = 1

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

enum FitnessEntityType: String, Codable, CaseIterable, Sendable {
    case sourceRecord = "source_record"
    case sourcePriority = "source_priority"
    case nutritionSettings = "nutrition_settings"
    case goal
    case goalRelationship = "goal_relationship"
    case trainingPhase = "training_phase"
    case workoutDefinition = "workout_definition"
    case trainingProgramme = "training_programme"
    case plannedSession = "planned_session"
    case food
    case foodVersion = "food_version"
    case foodServing = "food_serving"
    case foodLogEntry = "food_log_entry"
    case recipe
    case recipeVersion = "recipe_version"
    case mealTemplate = "meal_template"
    case nutritionTarget = "nutrition_target"
    case bodyMeasurement = "body_measurement"
    case exercise
    case exerciseSetup = "exercise_setup"
    case strengthSession = "strength_session"
    case strengthSessionExercise = "strength_session_exercise"
    case strengthSetGroup = "strength_set_group"
    case strengthSetComponent = "strength_set_component"
    case sessionCheckin = "session_checkin"
    case bodyIssue = "body_issue"
    case sleepSession = "sleep_session"
    case recoveryObservation = "recovery_observation"
    case progressPhoto = "progress_photo"
    case gear
    case manualActivity = "manual_activity"
    case activityContext = "activity_context"
    case activityGearLink = "activity_gear_link"
    case activityGoalLink = "activity_goal_link"
    case cycleSettings = "cycle_settings"
    case cyclePeriodStart = "cycle_period_start"
}

enum FitnessGoalRelationshipKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case supports, conflicts, dependsOn = "depends_on", subgoalOf = "subgoal_of"
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_",with: " ").capitalized }
}

struct FitnessGoalRelationship: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sourceGoalId: String
    var targetGoalId: String
    var relationship: FitnessGoalRelationshipKind
    var notes: String?
    var revision: Int
}

enum FitnessMutationOperation: String, Codable, Sendable {
    case upsert
    case delete
}

enum FitnessNextActionUrgency: String, Codable, Sendable {
    case routine, attention, urgent
}

struct FitnessNextActionEvidence: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let label: String
    let summary: String
}

struct FitnessNextActionCommand: Codable, Equatable, Sendable {
    let kind: String
    let target: String
    let label: String
}

struct FitnessNextAction: Codable, Identifiable, Equatable, Sendable {
    let title: String
    let body: String
    let urgency: FitnessNextActionUrgency
    let evidence: [FitnessNextActionEvidence]
    let action: FitnessNextActionCommand
    let secondaryAction: FitnessNextActionCommand?
    let expiresAt: String
    let source: String

    var id: String { source }
    var expiry: Date? { FitnessDatabase.date(expiresAt) }
}

enum FitnessMeal: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack, drink
    case preWorkout = "pre_workout"
    case duringWorkout = "during_workout"
    case postWorkout = "post_workout"
    case other
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum FitnessMeasurementSource: String, Codable, Sendable {
    case manual, imported, healthKit = "healthkit"
}

enum FitnessLoadMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case total = "total_kg"
    case each = "kg_each"
    case perSide = "kg_per_side"
    case machine = "machine_stack"
    case level = "machine_level"
    case bodyweight
    case added = "bodyweight_added"
    case assistance = "bodyweight_assistance"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .total: "Total kg"
        case .each: "kg each"
        case .perSide: "kg per side"
        case .machine: "Machine stack"
        case .level: "Machine level"
        case .bodyweight: "Bodyweight"
        case .added: "Added weight"
        case .assistance: "Assistance"
        }
    }
}

enum FitnessSetRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case warmup, working, backoff, technique, test, other
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum FitnessSetStructure: String, Codable, CaseIterable, Identifiable, Sendable {
    case straight, drop, restPause = "rest_pause", cluster, other
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum FitnessFailureType: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, technical, muscular
    case stoppedForBodyIssue = "stopped_for_body_issue"
    case unknown
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum FitnessWorkoutStatus: String, Codable, Sendable {
    case active, completed, abandoned
}

enum FitnessSetStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case planned, inProgress = "in_progress", completed, partial, skipped, aborted
    var id: String { rawValue }
    var title: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

enum FitnessComponentStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case completed, partial, skipped
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct FitnessGoal: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var metric: String
    var targetValue: Double?
    var unit: String?
    var targetDate: Date?
    var revision: Int
    var updatedAt: Date
}

enum FitnessGoalTemplateInputKind: String, Codable, Sendable {
    case sessionsPerWeek = "sessions_per_week"
    case kilometresPerWeek = "kilometres_per_week"
    case activeDaysPerWeek = "active_days_per_week"
    case targetWeightKg = "target_weight_kg"
    case durationMinutesSeconds = "duration_minutes_seconds"

    var usesWholeNumbers: Bool {
        switch self {
        case .sessionsPerWeek, .activeDaysPerWeek: true
        case .kilometresPerWeek, .targetWeightKg, .durationMinutesSeconds: false
        }
    }
}

/// Server-owned, human-facing goal choices. Internal measurement keys never
/// cross into the Plan UI.
struct FitnessGoalTemplate: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let targetPrompt: String
    let inputKind: FitnessGoalTemplateInputKind
    let unitLabel: String
    let minimumValue: Double
    let maximumValue: Double
    let step: Double
    let suggestedValue: Double
    let supportsTargetDate: Bool
}

struct FitnessGoalFromTemplateRequest: Codable, Equatable, Sendable {
    let id: String
    let templateId: String
    let targetValue: Double
    let startsOn: String
    let targetDate: String?
    let title: String?
    let priority: Int
    let clientId: String
    let clientTimestamp: String
}

struct FitnessGoalFromTemplateResponse: Codable, Equatable, Sendable {
    let goalId: String
    let templateId: String
    let title: String
    let targetText: String
    let startsOn: String
    let targetDate: String?
    let priority: Int
    let status: String
}

struct FitnessWeeklyReviewTotals: Codable, Equatable, Sendable {
    let completedSessions: Int
    let activeDays: Int
    let durationMinutes: Int?
    let distanceKm: Double?
    let strengthVolumeKg: Double?
}

struct FitnessWeeklyReviewGoalProgress: Codable, Equatable, Sendable {
    let goalId: String
    let goalName: String
    let progressText: String
    let progressPercent: Int?
}

struct FitnessWeeklyReviewHighlight: Codable, Equatable, Sendable {
    let title: String
    let detail: String
}

enum FitnessWeeklyReviewDestination: String, Codable, Sendable {
    case today, plan, activities, strength, goals, measurements
}

enum FitnessWeeklyReviewAction: String, Codable, Sendable {
    case planSession = "plan_session"
    case logActivity = "log_activity"
    case startStrength = "start_strength"
    case chooseGoal = "choose_goal"
    case logWeight = "log_weight"
    case reviewGoal = "review_goal"
}

struct FitnessWeeklyReviewOpportunity: Codable, Equatable, Sendable {
    let title: String
    let detail: String
    let destination: FitnessWeeklyReviewDestination
    let action: FitnessWeeklyReviewAction
    let actionLabel: String
}

struct FitnessWeeklyReview: Codable, Equatable, Sendable {
    let weekStart: String
    let weekEnd: String
    let totals: FitnessWeeklyReviewTotals
    let goal: FitnessWeeklyReviewGoalProgress?
    let highlight: FitnessWeeklyReviewHighlight
    let opportunity: FitnessWeeklyReviewOpportunity
}

struct FitnessWeightProgressPointDTO: Codable, Equatable, Identifiable, Sendable {
    let measurementId: String
    let measuredAtUtc: String
    let weightKg: Double
    var id: String { measurementId }
    var measuredAt: Date { FitnessDatabase.date(measuredAtUtc) ?? .distantPast }
}

enum FitnessRunningProgressSource: String, Codable, Sendable {
    case bestEffort = "best_effort"
    case averagePaceEstimate = "average_pace_estimate"

    var title: String {
        switch self {
        case .bestEffort: "Best effort"
        case .averagePaceEstimate: "Average-pace estimate"
        }
    }
}

struct FitnessRunningProgressPointDTO: Codable, Equatable, Identifiable, Sendable {
    let activityId: String
    let startedAtUtc: String
    let durationS: Double
    let source: FitnessRunningProgressSource
    var id: String { activityId }
    var startedAt: Date { FitnessDatabase.date(startedAtUtc) ?? .distantPast }
}

struct FitnessRunningProgressSeriesDTO: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let label: String
    let distanceM: Int
    let points: [FitnessRunningProgressPointDTO]
    var id: String { key }
}

struct FitnessStrengthProgressChartPointDTO: Codable, Equatable, Identifiable, Sendable {
    let activityId: String
    let performedAtUtc: String
    let loadKg: Double
    let repetitions: Int?
    let workingSetCount: Int
    var id: String { activityId }
    var performedAt: Date { FitnessDatabase.date(performedAtUtc) ?? .distantPast }
}

struct FitnessStrengthProgressChartSeriesDTO: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let label: String
    let exerciseId: String?
    let exerciseName: String?
    let setupId: String?
    let setupName: String?
    let points: [FitnessStrengthProgressChartPointDTO]
    var id: String { key }
}

struct FitnessProgressChartsDTO: Codable, Equatable, Sendable {
    let weight: [FitnessWeightProgressPointDTO]
    let running: [FitnessRunningProgressSeriesDTO]
    let strength: [FitnessStrengthProgressChartSeriesDTO]

    static let empty = FitnessProgressChartsDTO(
        weight: [],
        running: [
            .init(key: "5k",label: "5K",distanceM: 5_000,points: []),
            .init(key: "10k",label: "10K",distanceM: 10_000,points: []),
        ],
        strength: [
            .init(key: "squat",label: "Squat",exerciseId: nil,exerciseName: nil,setupId: nil,setupName: nil,points: []),
            .init(key: "chest_press",label: "Chest press",exerciseId: nil,exerciseName: nil,setupId: nil,setupName: nil,points: []),
            .init(key: "overhead_press",label: "Overhead press",exerciseId: nil,exerciseName: nil,setupId: nil,setupName: nil,points: []),
        ]
    )
}

enum FitnessPlanExperiencePolicy {
    static func nextSession(in plans: [FitnessPlannedSession]) -> FitnessPlannedSession? {
        plans.filter(\.isStartable).min {
            (planDate($0) ?? .distantFuture) < (planDate($1) ?? .distantFuture)
        }
    }

    static func sessions(
        on day: Date,
        in plans: [FitnessPlannedSession],
        calendar: Calendar = .current
    ) -> [FitnessPlannedSession] {
        plans.filter { plan in
            guard plan.isStartable, let date = planDate(plan) else { return false }
            return calendar.isDate(date, inSameDayAs: day)
        }
        .sorted { (planDate($0) ?? .distantFuture) < (planDate($1) ?? .distantFuture) }
    }

    static func week(containing date: Date = Date(), calendar: Calendar = .current) -> [Date] {
        var mondayCalendar=calendar
        mondayCalendar.firstWeekday=2
        let weekday=mondayCalendar.component(.weekday,from:date)
        let daysSinceMonday=(weekday-mondayCalendar.firstWeekday+7)%7
        let start=mondayCalendar.date(
            byAdding:.day,value:-daysSinceMonday,to:mondayCalendar.startOfDay(for:date)
        ) ?? mondayCalendar.startOfDay(for:date)
        return (0..<7).compactMap { mondayCalendar.date(byAdding:.day,value:$0,to:start) }
    }

    private static func planDate(_ plan: FitnessPlannedSession) -> Date? {
        plan.scheduledStart ?? plan.timeWindowStart ?? plan.plannedFor
    }
}

enum FitnessProgressLoadArea: Equatable {
    case home, strength, body, recovery, insights
}

enum FitnessGoalTrendKind: Equatable, Sendable {
    case sessions, activeDays, runningDistance, strengthSessions, weight

    static func resolve(metric:String) -> Self {
        let key=metric.lowercased()
        if key.contains("body.weight") { return .weight }
        if key.contains("running.distance") { return .runningDistance }
        if key.contains("strength") && key.contains("session") { return .strengthSessions }
        if key.contains("active_days") { return .activeDays }
        return .sessions
    }

    var title:String {
        switch self {
        case .sessions: "Weekly sessions"
        case .activeDays: "Active days"
        case .runningDistance: "Synthetic public demo record 2"
        case .strengthSessions: "Weekly strength sessions"
        case .weight: "Body-weight trend"
        }
    }

    var unit:String {
        switch self {
        case .sessions,.strengthSessions: "sessions"
        case .activeDays: "days"
        case .runningDistance: "km"
        case .weight: "kg"
        }
    }
}

enum FitnessProgressLoadPolicy {
    static func homeRequests(for area: FitnessProgressLoadArea) -> Set<String> {
        area == .home
            ? ["weekly-review", "activity-history", "progress-charts", "body-measurements"]
            : []
    }

    static func currentMonday(
        for date: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> Date {
        var calendar = inputCalendar
        calendar.firstWeekday = 2
        let weekday=calendar.component(.weekday,from:date)
        let daysSinceMonday=(weekday-calendar.firstWeekday+7)%7
        return calendar.date(
            byAdding:.day,value:-daysSinceMonday,to:calendar.startOfDay(for:date)
        ) ?? calendar.startOfDay(for:date)
    }

    static func fourWeekActivityFilter(
        for date:Date = Date(),
        calendar:Calendar = .current
    ) -> FitnessActivityFilter {
        let currentWeek=currentMonday(for:date,calendar:calendar)
        let firstDay=calendar.date(byAdding:.day,value:-21,to:currentWeek) ?? currentWeek
        let lastDay=calendar.date(byAdding:.day,value:6,to:currentWeek) ?? date
        var filter=FitnessActivityFilter()
        filter.dateFrom=calendarDate(firstDay,calendar:calendar)
        filter.dateTo=calendarDate(lastDay,calendar:calendar)
        return filter
    }

    private static func calendarDate(_ date:Date,calendar:Calendar) -> String {
        let components=calendar.dateComponents([.year,.month,.day],from:date)
        return String(
            format:"%04d-%02d-%02d",
            components.year ?? 0,components.month ?? 0,components.day ?? 0
        )
    }
}

enum FitnessInsightQuestion: String, CaseIterable, Identifiable, Sendable {
    case changed = "What changed this month?"
    case recovery = "Why has recovery fallen?"
    case goal = "Am I progressing toward my goal?"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .changed: "calendar.badge.clock"
        case .recovery: "moon.stars"
        case .goal: "target"
        }
    }

    func preferredPreset(in presets: [FitnessAnalysisRegistry.DefaultQuery]) -> FitnessAnalysisRegistry.DefaultQuery? {
        switch self {
        case .recovery:
            return presets.first { $0.id == "sleep-progress" }
                ?? presets.first { $0.label.localizedCaseInsensitiveContains("sleep") }
        case .goal:
            return presets.first { preset in
                ["weight-progress", "running-progress", "strength-progress"].contains(preset.id)
            }
        case .changed:
            return presets.first { $0.id == "running-progress" }
                ?? presets.first { $0.id == "strength-progress" }
                ?? presets.first
        }
    }
}

enum FitnessConsumerCopyPolicy {
    static let technicalTerms = [
        "source priority", "canonical", "unknown hardness", "scalar-repetition",
        "e1rm", "provider", "model confidence", "evidence", "validation", "stale",
    ]

    static func isConsumerFacing(_ copy: String) -> Bool {
        !technicalTerms.contains { copy.localizedCaseInsensitiveContains($0) }
    }
}

enum FitnessGoalLinkRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary, secondary, constraint
    var id: String { rawValue }
}

struct FitnessGoalLink: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var phaseId: String
    var goalId: String
    var role: FitnessGoalLinkRole
}

struct FitnessTrainingPhase: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var phaseType: String
    var name: String
    var startsOn: String
    var endsOn: String?
    var goalLinks: [FitnessGoalLink]
    var revision: Int
    var updatedAt: Date
}

struct FitnessFood: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var versionId: String
    var name: String
    var brand: String?
    var kcalPer100g: Double?
    var defaultServingGrams: Double?
    var isFavourite: Bool
    var isArchived: Bool
    var revision: Int
    var updatedAt: Date
    var categoryKey: String? = nil
    var barcode: String? = nil
    var notes: String? = nil
    var householdShared: Bool = false
    var active: Bool = true
    var mergedIntoFoodId: String? = nil
    var editable: Bool = true
    var versions: [FitnessFoodVersion] = []
    var servings: [FitnessFoodServing] = []
    var quickUse: FitnessFoodQuickUse? = nil

    var currentVersion: FitnessFoodVersion? {
        versions.first { $0.id == versionId } ?? versions.max { ($0.versionNumber ?? 0) < ($1.versionNumber ?? 0) }
    }
}

struct FitnessFoodLogEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var foodId: String?
    var foodVersionId: String?
    var foodName: String
    var loggedAt: Date
    var nutritionDate: String
    var meal: FitnessMeal
    var amountGrams: Double?
    var kcal: Double?
    var revision: Int
    var updatedAt: Date
    var recipeVersionId: String? = nil
    var localTimezone: String = TimeZone.current.identifier
    var enteredAmount: Double = 0
    var enteredUnit: String = "g"
    var canonicalAmount: Double = 0
    var canonicalUnit: String = "g"
    var proteinG: Double? = nil
    var carbohydrateG: Double? = nil
    var sugarsG: Double? = nil
    var fatG: Double? = nil
    var saturatedFatG: Double? = nil
    var fibreG: Double? = nil
    var saltG: Double? = nil
    var sodiumMg: Double? = nil
    var micronutrients: [String: Double?] = [:]
    var measurementQuality: FitnessNutritionMeasurementQuality = .estimated
    var notes: String? = nil
    var contextTags: [String] = []

    var nutrients: FitnessNutritionValues {
        FitnessNutritionValues(
            caloriesKcal: kcal, proteinG: proteinG, carbohydrateG: carbohydrateG,
            sugarsG: sugarsG, fatG: fatG, saturatedFatG: saturatedFatG,
            fibreG: fibreG, saltG: saltG, sodiumMg: sodiumMg,
            micronutrients: micronutrients
        )
    }
}

struct FitnessBodyMeasurement: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var metricKey: String
    var measuredAt: Date
    var value: Double
    var unitKey: String
    var notes: String?
    var measurementQuality: String
    var source: FitnessMeasurementSource
    var isCanonical: Bool
    var revision: Int
    var updatedAt: Date
    var sourceRecordId: String? = nil
    var sourceDetails: FitnessExternalSourceDTO? = nil
    var canonicalState: String = "canonical"
    var duplicateOfMeasurementId: String? = nil
    var manualCanonicalOverride: Bool = false

    /// Weight-only callers query `body.weight_kg`; retain the concise property
    /// without making the stored measurement model weight-specific.
    var weightKg: Double { value }
}

struct FitnessBodyMeasurementCanonicalOverrideResponse: Codable, Equatable, Sendable {
    let canonicalMeasurementId: String
    let groupMemberIds: [String]
    let manualOverride: Bool
}

struct FitnessExercise: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var category: String
    var primaryMuscle: String?
    var isFavourite: Bool
    var isCustom: Bool
    var isArchived: Bool
    var revision: Int
    var updatedAt: Date
    var seedKey: String? = nil
    var aliases: [String] = []
    var movementPatternKey: String = "other"
    var measurementMode: String = "reps_load"
    var repCountMode: String = "total"
    var loadEntryMode: String = "total_external"
    var defaultUnit: String = "kg"
    var unilateralMode: String = "bilateral"
    var equipmentType: String? = nil
    var bodyweightInvolved: Bool = false
    var progressionDirection: String = "higher"
    var notes: String? = nil
    var active: Bool = true
    var mergedIntoExerciseId: String? = nil
    var muscleRoles: [FitnessExerciseMuscleRole] = []
}

struct FitnessExerciseSetup: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var exerciseId: String
    var name: String
    var loadMode: FitnessLoadMode
    var incrementKg: Double?
    var barWeightKg: Double?
    var isDefault: Bool
    var revision: Int
    var updatedAt: Date
    var location: String? = nil
    var equipmentIdentifier: String? = nil
    var repCountMode: String = "total"
    var unilateralMode: String = "bilateral"
    var machineBaseLoadKg: Double? = nil
    var sideMultiplier: Double? = nil
    var notes: String? = nil
    var active: Bool = true
    var mergedIntoSetupId: String? = nil
}

struct FitnessPlannedSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var plannedFor: Date?
    var exerciseIds: [String]
    var isCompleted: Bool
    var revision: Int
    var updatedAt: Date
    var status: String = "proposed"
    var availableWindowMinutes: Int? = nil
    var intendedGear: String? = nil
    var sportKey: String = "strength"
    var timeWindowStart: Date? = nil
    var timeWindowEnd: Date? = nil
    var expectedDurationSeconds: Double? = nil
    var expectedDistanceMetres: Double? = nil
    var expectedPaceSecondsPerKilometre: Double? = nil
    var intendedGearIds: [String] = []
    var trainingProgrammeId: String? = nil
    var workoutVersionId: String? = nil
    var scheduledStart: Date? = nil
    var scheduledDate: String? = nil
    var priority: Int = 0
    var movable: Bool = true
    var visibility: String = "private"
    var sharedTitle: String? = nil
    var reasonForPlacement: String? = nil
    var sessionSource: String = "user"
    var completionActivityId: String? = nil
    var completionState: String? = nil
    var goalLinks: [FitnessPlannedSessionGoalLink] = []

    var isStartable: Bool {
        ["accepted","scheduled","in_progress"].contains(status) && !isCompleted
    }
}

struct FitnessPlannedSessionGoalLink: Codable,Identifiable,Equatable,Sendable {
    var goalId: String
    var role: String
    var id: String { "\(goalId):\(role)" }
}

struct FitnessPlannedSessionEditDraft: Equatable,Sendable {
    var id: String
    var baseRevision: Int
    var sportKey: String
    var title: String
    var precision: FitnessSchedulePrecision
    var scheduledStart: Date
    var windowEnd: Date
    var scheduledDate: Date
    var expectedDurationSeconds: Int?
    var expectedDistanceMetres: Double?
    var expectedPaceSecondsPerKilometre: Double?
    var programmeId: String?
    var workoutVersionId: String?
    var status: String
    var movable: Bool
    var visibility: String
    var sharedTitle: String?
    var reasonForPlacement: String?
    var primaryGoalId: String?
    var otherGoalLinks: [FitnessPlannedSessionGoalLink]
    var intendedGearIds: [String]
    var priority: Int
    var sessionSource: String
    var completionActivityId: String?
    var completionState: String?

    init(session: FitnessPlannedSession) {
        id=session.id; baseRevision=session.revision; sportKey=session.sportKey; title=session.title
        if session.scheduledStart != nil { precision = .exact }
        else if session.timeWindowStart != nil { precision = .window }
        else { precision = .date }
        scheduledStart=session.scheduledStart ?? session.timeWindowStart ?? session.plannedFor ?? Date()
        windowEnd=session.timeWindowEnd ?? scheduledStart.addingTimeInterval(3_600)
        scheduledDate=session.plannedFor ?? Date()
        expectedDurationSeconds=session.expectedDurationSeconds.map { Int($0.rounded()) }
        expectedDistanceMetres=session.expectedDistanceMetres
        expectedPaceSecondsPerKilometre=session.expectedPaceSecondsPerKilometre
        programmeId=session.trainingProgrammeId
        workoutVersionId=session.workoutVersionId; status=session.status; movable=session.movable
        visibility=session.visibility; sharedTitle=session.sharedTitle
        reasonForPlacement=session.reasonForPlacement
        primaryGoalId=session.goalLinks.first { $0.role == "primary" }?.goalId
        otherGoalLinks=session.goalLinks.filter { $0.role != "primary" }
        intendedGearIds=session.intendedGearIds; priority=session.priority
        sessionSource=session.sessionSource; completionActivityId=session.completionActivityId
        completionState=session.completionState
    }
}

struct FitnessStrengthSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var status: FitnessWorkoutStatus
    var startedAt: Date
    var endedAt: Date?
    var plannedSessionId: String?
    var readiness: Int?
    var sessionRPE: Double?
    var performance: Int?
    var note: String?
    var revision: Int
    var updatedAt: Date
    var localTimezone: String = TimeZone.current.identifier
    var restTimerDeadline: Date? = nil
    var bodyweightKgSnapshot: Double? = nil
    var bodyweightSource: String? = nil
    var matchedPlanKey: String? = nil
}

struct FitnessSessionExercise: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sessionId: String
    var exerciseId: String
    var exerciseName: String
    var setupId: String
    var setupName: String
    var position: Int
    var revision: Int
    var updatedAt: Date
    var plannedExerciseId: String? = nil
    var setupLoadModeSnapshot: String = "total_external"
    var repCountModeSnapshot: String = "total"
    var unilateralModeSnapshot: String = "bilateral"
    var supersetGroupKey: String? = nil
    var variationNote: String? = nil
    var notes: String? = nil
}

struct FitnessSetGroup: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sessionExerciseId: String
    var role: FitnessSetRole
    var structure: FitnessSetStructure
    var isAMRAP: Bool
    var failureState: FitnessFailureType
    var status: FitnessSetStatus
    var position: Int
    var revision: Int
    var updatedAt: Date
    var plannedSetId: String? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var notes: String? = nil
}

struct FitnessSetComponent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var groupId: String
    var status: FitnessComponentStatus
    var loadKg: Double?
    var reps: Int?
    var durationSeconds: Int?
    var distanceMetres: Double?
    var rir: Double?
    var rpe: Double?
    var completedAt: Date?
    var position: Int
    var revision: Int
    var updatedAt: Date
    var repsLeft: Int? = nil
    var repsRight: Int? = nil
    var loadValue: Double? = nil
    var loadUnit: String? = nil
    var loadEntryModeSnapshot: String? = nil
    var normalizedExternalLoadKg: Double? = nil
    var addedLoadKg: Double? = nil
    var assistanceKg: Double? = nil
    var bodyweightKgSnapshot: Double? = nil
    var restBeforeSeconds: Int? = nil
    var tempoText: String? = nil
    var notes: String? = nil
    var extraMetrics: [String: JSONValue] = [:]
}

struct FitnessWorkoutExercise: Identifiable, Equatable, Sendable {
    var exercise: FitnessSessionExercise
    var groups: [FitnessWorkoutGroup]
    var id: String { exercise.id }
}

struct FitnessWorkoutGroup: Identifiable, Equatable, Sendable {
    var group: FitnessSetGroup
    var components: [FitnessSetComponent]
    var id: String { group.id }
}

struct FitnessBodyIssue: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var sessionId: String?
    var issueTypeKey: String
    var bodyLocationKey: String
    var side: String
    var severity: Int
    var timing: String
    var changedSession: Bool
    var sessionChangeKey: String
    var note: String?
    var observedAt: Date
    var resolvedAt: Date?
    var revision: Int
    var updatedAt: Date
    var plannedSessionId: String? = nil
    var sessionExerciseId: String? = nil
    var setGroupId: String? = nil
    var checkinId: String? = nil
    var trendKey: String = "unknown"
    var status: String = "active"
}

struct FitnessDiarySummary: Equatable, Sendable {
    var entries: [FitnessFoodLogEntry]
    var totalKcal: Double
}

struct FitnessStrengthSummary: Equatable, Sendable {
    var sessionId: String
    var title: String
    var endedAt: Date
    var workingSets: Int
    var hardSets: Int
    var volumeKg: Double
    var estimatedOneRepMaxKg: Double?
}

enum FitnessCalculations {
    static func nutritionDate(
        for date: Date,
        dayStartMinutes: Int = 240,
        calendar: Calendar = .current
    ) -> String {
        let safeBoundary = min(max(dayStartMinutes, 0), 480)
        let shifted = calendar.date(byAdding: .minute, value: -safeBoundary, to: date) ?? date
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: shifted)
    }

    static func nutritionAnalysisRange(
        endingOn nutritionDate: String,
        days: Int,
        calendar: Calendar = .current
    ) -> (start: String,end: String)? {
        guard days > 0 else { return nil }
        let formatter=DateFormatter()
        formatter.calendar=calendar
        formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.timeZone=calendar.timeZone
        formatter.dateFormat="yyyy-MM-dd"
        guard let endDate=formatter.date(from:nutritionDate),
              let startDate=calendar.date(byAdding:.day,value:1-days,to:endDate) else {
            return nil
        }
        return (formatter.string(from:startDate),nutritionDate)
    }

    static func nutritionDayDate(
        _ nutritionDate: String,
        addingDays: Int=0,
        calendar: Calendar = .current
    ) -> Date? {
        let formatter=DateFormatter()
        formatter.calendar=calendar
        formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.timeZone=calendar.timeZone
        formatter.dateFormat="yyyy-MM-dd"
        guard let date=formatter.date(from:nutritionDate) else { return nil }
        return calendar.date(byAdding:.day,value:addingDays,to:date)
    }

    static func nutritionTargetBalance(target: Double,consumed: Double) -> Double {
        target-consumed
    }

    static func nutritionBalanceText(_ balance: Double,unit: String) -> String {
        let value=Int(abs(balance).rounded())
        return balance < 0 ? "\(value) \(unit) over" : "\(value) \(unit) remaining"
    }

    static func sevenDayTrend(_ measurements: [FitnessBodyMeasurement]) -> Double? {
        let canonical = measurements.filter {
            $0.metricKey == "body.weight_kg" && $0.isCanonical
        }.sorted { $0.measuredAt > $1.measuredAt }
        guard !canonical.isEmpty else { return nil }
        return canonical.prefix(7).map(\.weightKg).reduce(0, +) / Double(min(7, canonical.count))
    }

    static func isHardSet(group: FitnessSetGroup, components: [FitnessSetComponent]) -> Bool {
        guard group.status != .skipped && group.status != .aborted else { return false }
        let performed = components.filter(isPerformed)
        guard !performed.isEmpty else { return false }
        return group.failureState == .technical || group.failureState == .muscular
            || performed.contains { component in
                component.rir.map { (0...3).contains($0) } == true
                || component.rpe.map { (7...10).contains($0) } == true
            }
    }

    static func volume(_ components: [FitnessSetComponent]) -> Double {
        components.filter(isPerformed).reduce(0) { result, component in
            // A left/right entry represents observed work on both sides. Summing
            // sides is defensible for volume only; records and e1RM use the
            // conservative scalar/minimum rules below.
            let reps = component.reps
                ?? ((component.repsLeft ?? 0) + (component.repsRight ?? 0))
            return result + (component.normalizedExternalLoadKg ?? component.loadKg ?? 0) * Double(reps)
        }
    }

    static func epley(loadKg: Double?, reps: Int?) -> Double? {
        guard let loadKg, let reps, loadKg > 0, (1...10).contains(reps) else { return nil }
        return loadKg * (1 + Double(reps) / 30)
    }

    static func eligibleEpley(group: FitnessSetGroup, components: [FitnessSetComponent]) -> Double? {
        guard group.structure == .straight,
              group.role == .working || group.role == .backoff || group.role == .test,
              isHardSet(group: group, components: components) else { return nil }
        return components.filter(isPerformed).compactMap { component in
            guard let load = component.normalizedExternalLoadKg ?? component.loadKg,
                  load > 0,
                  // Left/right entries prove performed work but are not silently
                  // collapsed into one scalar repetition count for e1RM.
                  let reps = component.reps,
                  reps > 0,
                  !["assistance", "machine_level", "bodyweight_only"].contains(component.loadEntryModeSnapshot ?? "")
            else { return nil }
            let effectiveReps: Double?
            if let rir = component.rir, (0...3).contains(rir) {
                effectiveReps = Double(reps) + rir
            } else if let rpe = component.rpe, (7...10).contains(rpe) {
                effectiveReps = Double(reps) + (10 - rpe)
            } else if group.failureState == .technical || group.failureState == .muscular {
                effectiveReps = Double(reps)
            } else {
                effectiveReps = nil
            }
            guard let effectiveReps, effectiveReps <= 10 else { return nil }
            return load * (1 + effectiveReps / 30)
        }.max()
    }

    static func isPerformed(_ component: FitnessSetComponent) -> Bool {
        switch component.status {
        case .skipped:
            false
        case .completed:
            true
        case .partial:
            (component.reps ?? 0) > 0
                || (component.repsLeft ?? 0) > 0
                || (component.repsRight ?? 0) > 0
                || (component.durationSeconds ?? 0) > 0
                || (component.distanceMetres ?? 0) > 0
        }
    }
}
