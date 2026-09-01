import Foundation

enum FitnessCoachPersonalityPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case scientificHardDriving = "scientific_hard_driving"
    case balancedSupportive = "balanced_supportive"
    case calmEncouraging = "calm_encouraging"
    case custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scientificHardDriving: "Scientific & hard-driving"
        case .balancedSupportive: "Balanced & supportive"
        case .calmEncouraging: "Calm & encouraging"
        case .custom: "Custom"
        }
    }
    var defaults: (directness: Int,challenge: FitnessCoachChallengeBias,detail: FitnessCoachDetailLevel) {
        switch self {
        case .scientificHardDriving: (5,.ambitious,.detailed)
        case .balancedSupportive: (3,.balanced,.standard)
        case .calmEncouraging: (2,.conservative,.standard)
        case .custom: (3,.balanced,.standard)
        }
    }
}

enum FitnessCoachChallengeBias: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative, balanced, ambitious
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum FitnessCoachDetailLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case brief, standard, detailed
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct FitnessCoachPreferences: Codable, Equatable, Sendable {
    var personalityPreset: FitnessCoachPersonalityPreset
    var directness: Int
    var challengeBias: FitnessCoachChallengeBias
    var detailLevel: FitnessCoachDetailLevel
    var customInstruction: String?
    var coachMemoryEnabled: Bool? = nil
    var coachMemoryEnabledAt: String? = nil

    static let balanced = Self(
        personalityPreset: .balancedSupportive,directness: 3,
        challengeBias: .balanced,detailLevel: .standard,customInstruction: nil
    )

    var isValid: Bool {
        (1...5).contains(directness) && (customInstruction?.count ?? 0) <= 500
    }
}

struct FitnessCoachPreferencesUpdate: Codable, Equatable, Sendable {
    let personalityPreset: FitnessCoachPersonalityPreset
    let directness: Int
    let challengeBias: FitnessCoachChallengeBias
    let detailLevel: FitnessCoachDetailLevel
    let customInstruction: String?

    init(_ preferences: FitnessCoachPreferences) {
        personalityPreset=preferences.personalityPreset; directness=preferences.directness
        challengeBias=preferences.challengeBias; detailLevel=preferences.detailLevel
        customInstruction=preferences.customInstruction
    }
}

enum FitnessCoachIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case discussion, morning, weekly, postWorkout = "post_workout", evening
    case runPlan = "run_plan"
    case strengthPlan = "strength_plan"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .discussion: "Discuss"
        case .morning: "Morning"
        case .weekly: "Weekly review"
        case .postWorkout: "Post-workout"
        case .evening: "Evening"
        case .runPlan: "Plan a run"
        case .strengthPlan: "Plan strength"
        }
    }
    var prompt: String {
        switch self {
        case .discussion: "What matters most in my training record right now?"
        case .morning: "Is there one useful adjustment for today?"
        case .weekly: "Review this week: the main success, constraint, and at most two changes."
        case .postWorkout: "Review the workout I just completed: what the evidence supports, what to recover from, and whether anything needs follow-up."
        case .evening: "Give me a brief evidence-backed review of today and the most useful preparation for tomorrow."
        case .runPlan: "Propose a complete reviewable run that supports my active goal and schedule."
        case .strengthPlan: "Propose a complete reviewable strength session using my exercises and compatible setups."
        }
    }
    var icon: String {
        switch self {
        case .discussion: "bubble.left.and.text.bubble.right"
        case .morning: "sparkles"
        case .weekly: "list.clipboard"
        case .postWorkout: "figure.cooldown"
        case .evening: "moon.stars"
        case .runPlan: "figure.run"
        case .strengthPlan: "dumbbell"
        }
    }
}

enum FitnessCoachAvailability: String, Codable, Sendable { case available, unavailable }

struct FitnessCoachStatus: Codable, Equatable, Sendable {
    let status: FitnessCoachAvailability
    let provider: String?
    let model: String?
    let message: String?
    let intents: [FitnessCoachIntent]?
}

enum FitnessCoachRole: String, Codable, Sendable { case user, assistant }

struct FitnessCoachHistoryTurn: Codable, Equatable, Sendable {
    let role: FitnessCoachRole
    let content: String
}

struct FitnessCoachMessageRequest: Codable, Equatable, Sendable {
    let message: String
    let intent: FitnessCoachIntent
    let history: [FitnessCoachHistoryTurn]
    let timezone: String
    let clientNow: String
    var conversationId: String? = nil
    var ephemeral: Bool = false
    var contextIds: [String] = []
}

struct FitnessCoachMemoryCandidate: Codable, Equatable, Sendable {
    let content: String
    let category: String?

    var key: String { "\(category ?? "")|\(content)" }
}

struct FitnessCoachMemorySettings: Codable, Equatable, Sendable {
    let enabled: Bool
    let enabledAt: String?
}

struct FitnessCoachMemorySettingsUpdate: Codable, Equatable, Sendable {
    let enabled: Bool
}

struct FitnessCoachContextPreferences: Codable, Equatable, Sendable {
    let familyCalendar: Bool
    let householdMeals: Bool
    let weather: Bool

    static let privateFitnessOnly = Self(
        familyCalendar: false,
        householdMeals: false,
        weather: false
    )
}

struct FitnessCoachContextPreferencesUpdate: Encodable, Equatable, Sendable {
    let familyCalendar: Bool
    let householdMeals: Bool
    let weather: Bool
}

enum FitnessCoachContextOption: String, CaseIterable, Identifiable, Sendable {
    case familyCalendar
    case householdMeals
    case weather

    var id: String { rawValue }
}

struct FitnessCoachReminder: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let remindAtUtc: String
    let notes: String?
    let plannedSessionId: String?
    let status: Status

    enum Status: String, Codable, Sendable {
        case active, completed
    }
}

struct FitnessCoachConversation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let lastMessageAt: String?
    let revision: Int
    let createdAt: String
    let updatedAt: String
}

struct FitnessCoachConversationCreate: Codable, Equatable, Sendable {
    let id: String?
    let title: String?
}

struct FitnessCoachStoredMessage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let conversationId: String
    let sequence: Int
    let role: FitnessCoachRole
    let content: String
    let intent: FitnessCoachIntent?
    let createdAt: String
}

struct FitnessCoachConversationDetail: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let lastMessageAt: String?
    let revision: Int
    let createdAt: String
    let updatedAt: String
    let messages: [FitnessCoachStoredMessage]
}

struct FitnessCoachMemory: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var content: String
    var category: String?
    let confirmedAt: String
    let revision: Int
    let createdAt: String
    let updatedAt: String
}

struct FitnessCoachMemoryCreate: Codable, Equatable, Sendable {
    let id: String?
    let content: String
    let category: String?
}

struct FitnessCoachMemoryUpdate: Encodable, Equatable, Sendable {
    let content: String
    let category: String?

    private enum CodingKeys: String,CodingKey { case content,category }
    func encode(to encoder: Encoder) throws {
        var values=encoder.container(keyedBy: CodingKeys.self)
        try values.encode(content,forKey: .content)
        try values.encode(category,forKey: .category) // Explicit null clears a category.
    }
}

struct FitnessCoachMemoryClearResult: Codable, Equatable, Sendable {
    let conversations: Int
    let messages: Int
    let memories: Int
}

struct FitnessCoachEvidence: Codable, Identifiable, Equatable, Sendable {
    struct Period: Codable, Equatable, Sendable {
        let start: String
        let end: String
    }
    let id: String
    let kind: String
    let label: String
    let summary: String
    let period: Period?
    let sampleSize: Int?
    let completeness: Double?
    let sourceIds: [String]?
}

enum FitnessCoachProposalKind: Codable, CaseIterable, Hashable, Sendable {
    case runWorkout
    case strengthWorkout
    case trainingWeek
    case nutritionChange
    case goalAdjustment
    case calendarChange
    case familyCalendarEvent
    case plannedMealLog
    case shoppingList
    case familyTask
    case fitnessReminder
    case chart
    case unknown(String)

    static let allCases: [Self] = [
        .runWorkout, .strengthWorkout, .trainingWeek, .nutritionChange,
        .goalAdjustment, .calendarChange, .familyCalendarEvent, .plannedMealLog,
        .shoppingList, .familyTask, .fitnessReminder, .chart,
    ]

    var rawValue: String {
        switch self {
        case .runWorkout: "run_workout"
        case .strengthWorkout: "strength_workout"
        case .trainingWeek: "training_week"
        case .nutritionChange: "nutrition_change"
        case .goalAdjustment: "goal_adjustment"
        case .calendarChange: "calendar_change"
        case .familyCalendarEvent: "family_calendar_event"
        case .plannedMealLog: "planned_meal_log"
        case .shoppingList: "shopping_list"
        case .familyTask: "family_task"
        case .fitnessReminder: "fitness_reminder"
        case .chart: "chart"
        case .unknown(let value): value
        }
    }

    var label: String {
        switch self {
        case .runWorkout: "Run workout"
        case .strengthWorkout: "Strength workout"
        case .trainingWeek: "Training week"
        case .nutritionChange: "Nutrition change"
        case .goalAdjustment: "Goal change"
        case .calendarChange: "Move planned session"
        case .familyCalendarEvent: "Family Calendar event"
        case .plannedMealLog: "Diary entry"
        case .shoppingList: "Shopping list"
        case .familyTask: "Family task"
        case .fitnessReminder: "Fitness reminder"
        case .chart: "Saved chart"
        case .unknown: "Coach suggestion"
        }
    }

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = switch rawValue {
        case "run_workout": .runWorkout
        case "strength_workout": .strengthWorkout
        case "training_week": .trainingWeek
        case "nutrition_change": .nutritionChange
        case "goal_adjustment": .goalAdjustment
        case "calendar_change": .calendarChange
        case "family_calendar_event": .familyCalendarEvent
        case "planned_meal_log": .plannedMealLog
        case "shopping_list": .shoppingList
        case "family_task": .familyTask
        case "fitness_reminder": .fitnessReminder
        case "chart": .chart
        default: .unknown(rawValue)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct FitnessCoachValidationIssue: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(code ?? "issue")|\(path ?? "")|\(message)" }
    let code: String?
    let path: String?
    let message: String
}

struct FitnessCoachProposalValidation: Codable, Equatable, Sendable {
    let valid: Bool
    let issues: [FitnessCoachValidationIssue]
}

enum FitnessCoachProposalVisibility: Codable, Hashable, Sendable {
    case privateToYou
    case visibleToFamily
    case unknown(String)

    var rawValue: String {
        switch self {
        case .privateToYou: "Private to you"
        case .visibleToFamily: "Visible to your family"
        case .unknown(let value): value
        }
    }

    var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "Private to you": .privateToYou
        case "Visible to your family": .visibleToFamily
        default: .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct FitnessCoachProposalPreview: Codable, Equatable, Sendable {
    let change: [String]
    let visibility: FitnessCoachProposalVisibility

    var isComplete: Bool {
        visibility.isKnown
            && (1...40).contains(change.count)
            && change.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// The only proposal content presented to a person. New cross-module actions
/// use the server-authored preview verbatim; established Fitness actions are
/// translated from their bounded typed payloads. No generic JSON fallback is
/// permitted here.
struct FitnessCoachProposalReview: Equatable, Sendable {
    let change: [String]
    let visibility: FitnessCoachProposalVisibility

    var isComplete: Bool {
        visibility.isKnown
            && (1...80).contains(change.count)
            && change.allSatisfy {
                let value=$0.trimmingCharacters(in:.whitespacesAndNewlines)
                return !value.isEmpty && value.count <= 1_200
            }
    }
}

enum FitnessCoachWarning: Codable, Equatable, Sendable {
    case message(String)
    case detail(code: String?,message: String)

    var text: String {
        switch self {
        case .message(let value): value
        case .detail(_,let message): message
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .message(value)
        } else {
            let value = try container.decode(Detail.self)
            self = .detail(code: value.code,message: value.message)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .message(let value): try container.encode(value)
        case .detail(let code,let message): try container.encode(Detail(code: code,message: message))
        }
    }

    private struct Detail: Codable { let code: String?; let message: String }
}

struct FitnessCoachProposal: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: FitnessCoachProposalKind
    let payload: [String: JSONValue]
    var preview: FitnessCoachProposalPreview? = nil
    let validation: FitnessCoachProposalValidation
    let warnings: [FitnessCoachWarning]
    var confirmable: Bool? = nil
    var reviewOnlyReason: String? = nil
    let expiresAt: String

    var isExpired: Bool {
        guard let date = FitnessDatabase.date(expiresAt) else { return true }
        return date <= Date()
    }
    var canConfirm: Bool {
        let compatibleServerApproval = confirmable ?? [
            FitnessCoachProposalKind.runWorkout,.strengthWorkout,.trainingWeek,.calendarChange,
        ].contains(kind)
        return kind.isKnown && compatibleServerApproval && validation.valid && !isExpired
            && humanReview?.isComplete == true
    }
    var canEdit: Bool {
        kind.isKnown && humanReview?.isComplete == true
    }
    var previewIsComplete: Bool {
        switch kind {
        case .familyCalendarEvent, .plannedMealLog, .shoppingList, .familyTask,
             .fitnessReminder:
            preview?.isComplete == true
        case .runWorkout:
            FitnessCoachRunProposal(payload: payload)?.flattenedSteps.complete == true
        case .strengthWorkout:
            FitnessCoachStrengthProposal(payload: payload)?.previewIsComplete == true
        case .trainingWeek:
            FitnessCoachTrainingWeekProposal(payload:payload)?.previewIsComplete == true
        case .nutritionChange:
            nutritionReview != nil
        case .goalAdjustment:
            goalReview != nil
        case .calendarChange:
            calendarReview != nil
        case .chart:
            chartReview != nil
        case .unknown: false
        }
    }

    var humanReview: FitnessCoachProposalReview? {
        let visibility:FitnessCoachProposalVisibility = .privateToYou
        switch kind {
        case .familyCalendarEvent, .plannedMealLog, .shoppingList, .familyTask,
             .fitnessReminder:
            guard let preview,preview.isComplete else { return nil }
            return FitnessCoachProposalReview(
                change:preview.change,visibility:preview.visibility
            )
        case .runWorkout:
            guard let run=FitnessCoachRunProposal(payload:payload),
                  run.flattenedSteps.complete else { return nil }
            return FitnessCoachProposalReview(
                change:Self.runReview(run),visibility:visibility
            )
        case .strengthWorkout:
            guard let strength=FitnessCoachStrengthProposal(payload:payload),
                  strength.previewIsComplete else { return nil }
            return FitnessCoachProposalReview(
                change:Self.strengthReview(strength),visibility:visibility
            )
        case .trainingWeek:
            guard let week=FitnessCoachTrainingWeekProposal(payload:payload),
                  week.previewIsComplete else { return nil }
            var rows=[week.name,week.purpose,week.startsOn.map { "Starts \($0)" }]
                .compactMap { $0 }
            rows += week.sessions.map {
                "\($0.scheduledDate) · \($0.title) · \($0.sportKey.capitalized)"
            }
            return FitnessCoachProposalReview(change:rows,visibility:visibility)
        case .nutritionChange:
            return nutritionReview.map {
                FitnessCoachProposalReview(change:$0,visibility:visibility)
            }
        case .goalAdjustment:
            return goalReview.map {
                FitnessCoachProposalReview(change:$0,visibility:visibility)
            }
        case .calendarChange:
            return calendarReview.map {
                FitnessCoachProposalReview(change:$0,visibility:visibility)
            }
        case .chart:
            return chartReview.map {
                FitnessCoachProposalReview(change:$0,visibility:visibility)
            }
        case .unknown:
            return nil
        }
    }

    private var nutritionReview:[String]? {
        guard let subject=payload.string("food_or_meal"),
              let change=payload.string("proposed_change"),
              let effect=payload.string("expected_effect") else { return nil }
        return [subject,change,"Expected: \(effect)"]
    }

    private var goalReview:[String]? {
        guard let name=payload.string("goal_name"),
              let reason=payload.string("reason") else { return nil }
        let current=payload.string("current_target")
            ?? Self.typedTarget(payload,prefix:"current")
        let proposed=payload.string("proposed_target")
            ?? Self.typedTarget(payload,prefix:"proposed")
        guard let proposed else { return nil }
        return [name,current.map { "Current: \($0)" },"Change to \(proposed)",reason]
            .compactMap { $0 }
    }

    private var calendarReview:[String]? {
        guard let title=payload.string("title"),
              let proposed=payload.string("proposed_start_utc"),
              let reason=payload.string("reason") else { return nil }
        let current=payload.string("current_start_utc")
            ?? payload.string("current_scheduled_date")
            ?? payload.string("current_window_start_utc")
        return [
            title,current.map { "Currently \(Self.humanDate($0))" },
            "Move to \(Self.humanDate(proposed))",reason,
        ].compactMap { $0 }
    }

    private var chartReview:[String]? {
        guard let name=payload.string("name"),
              let measure=payload.string("measure_key"),
              let dimension=payload.string("dimension_key"),
              let chartType=payload.string("chart_type_key"),
              let days=payload.integer("date_window_days") else { return nil }
        return [
            name,
            "\(Self.humanKey(measure)) by \(Self.humanKey(dimension))",
            "\(Self.humanKey(chartType)) · last \(days) days",
        ]
    }

    private static func runReview(_ run:FitnessCoachRunProposal) -> [String] {
        var rows=[run.title,run.purpose]
            .compactMap { $0 }
        if let date=run.scheduledStartUtc ?? run.scheduledDate {
            rows.append("Scheduled \(humanDate(date))")
        }
        let distance=run.estimatedDistanceM.map(humanDistance)
        let duration=run.estimatedDurationS.map(humanDuration)
        let scale=[distance,duration].compactMap { $0 }.joined(separator:" · ")
        if !scale.isEmpty { rows.append(scale) }
        rows += run.flattenedSteps.rows.map { row in
            let name=row.step.displayName ?? "Step"
            let effort=[
                row.step.durationValue.map { "\($0.formatted()) \(humanKey(row.step.durationType ?? ""))" },
                humanRange(row.step.targetLow,row.step.targetHigh,unit:row.step.targetUnit ?? row.step.targetType),
            ].compactMap { $0 }.joined(separator:" · ")
            return effort.isEmpty ? "\(row.path). \(name)" : "\(row.path). \(name) · \(effort)"
        }
        return rows
    }

    private static func strengthReview(_ value:FitnessCoachStrengthProposal) -> [String] {
        var rows=[value.title,value.purpose]
            .compactMap { $0 }
        if let date=value.scheduledStartUtc ?? value.scheduledDate {
            rows.append("Scheduled \(humanDate(date))")
        }
        if let duration=value.estimatedDurationS { rows.append(humanDuration(duration)) }
        rows += value.exercises.map { exercise in
            let prescription=exercise.sets.compactMap { set -> String? in
                let reps=humanRange(
                    set.repsMin.map(Double.init),set.repsMax.map(Double.init),unit:"reps"
                )
                let load=humanRange(set.loadMin,set.loadMax,unit:set.loadUnit ?? set.loadMode)
                let parts=[load,reps].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator:" × ")
            }.prefix(3).joined(separator:", ")
            return prescription.isEmpty
                ? exercise.exerciseName
                : "\(exercise.exerciseName) · \(prescription)"
        }
        return rows
    }

    private static func typedTarget(
        _ payload:[String:JSONValue],prefix:String
    ) -> String? {
        let value=payload.number("\(prefix)_target_value")?.formatted()
        let unit=payload.string("unit_key").map(humanKey)
        let date=payload.string("\(prefix)_target_date")
        let amount=[value,unit].compactMap { $0 }.joined(separator:" ")
        let result=[amount.isEmpty ? nil : amount,date].compactMap { $0 }.joined(separator:" · ")
        return result.isEmpty ? nil : result
    }

    private static func humanDate(_ raw:String) -> String {
        guard let date = ISODateParser.parse(raw) else { return raw }
        return date.formatted(date:.abbreviated,time:.shortened)
    }

    private static func humanKey(_ raw:String) -> String {
        raw.replacingOccurrences(of:"_",with:" ")
            .replacingOccurrences(of:".",with:" ")
            .trimmingCharacters(in:.whitespacesAndNewlines)
            .capitalized
    }

    private static func humanDuration(_ seconds:Double) -> String {
        let minutes=Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    private static func humanDistance(_ metres:Double) -> String {
        metres >= 1_000
            ? String(format:"%.1f km",metres / 1_000)
            : "\(Int(metres.rounded())) m"
    }

    private static func humanRange(
        _ low:Double?,_ high:Double?,unit:String?
    ) -> String? {
        guard let value=low ?? high else { return nil }
        let core: String
        if let low,let high,low != high { core="\(low.formatted())–\(high.formatted())" }
        else { core=value.formatted() }
        let label=unit.map(humanKey) ?? ""
        return [core,label].filter { !$0.isEmpty }.joined(separator:" ")
    }
}

enum FitnessCoachResponseStatus: String, Codable, Sendable { case complete, unavailable }

struct FitnessCoachMessageResponse: Codable, Equatable, Sendable {
    let status: FitnessCoachResponseStatus
    let answer: String
    let evidence: [FitnessCoachEvidence]
    let recommendation: FitnessCoachRecommendation?
    let proposal: FitnessCoachProposal?
    var conversationId: String? = nil
    var memoryCandidates: [FitnessCoachMemoryCandidate]? = nil
}

enum FitnessCoachDecisionStatus: String, Codable, Sendable {
    case confirmed, declined, expired, invalid
}

struct FitnessCoachProposalDecision: Codable, Equatable, Sendable {
    let status: FitnessCoachDecisionStatus
    let message: String
    let resultIds: [String]?
    let nextDestinations: [FitnessCoachProposalDestination]?
}

enum FitnessCoachProposalDestinationKind:Codable,Hashable,Sendable {
    case plannedSession
    case nutritionTarget
    case mealTemplate
    case goal
    case analysisChart
    case calendarEvent
    case foodLog
    case shopping
    case task
    case fitnessReminder
    case unknown(String)

    var rawValue:String {
        switch self {
        case .plannedSession:"planned_session"
        case .nutritionTarget:"nutrition_target"
        case .mealTemplate:"meal_template"
        case .goal:"goal"
        case .analysisChart:"analysis_chart"
        case .calendarEvent:"calendar_event"
        case .foodLog:"food_log"
        case .shopping:"shopping"
        case .task:"task"
        case .fitnessReminder:"fitness_reminder"
        case .unknown(let value):value
        }
    }

    var isKnown:Bool {
        if case .unknown = self { return false }
        return true
    }

    init(from decoder:Decoder) throws {
        let value=try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "planned_session":.plannedSession
        case "nutrition_target":.nutritionTarget
        case "meal_template":.mealTemplate
        case "goal":.goal
        case "analysis_chart":.analysisChart
        case "calendar_event":.calendarEvent
        case "food_log":.foodLog
        case "shopping":.shopping
        case "task":.task
        case "fitness_reminder":.fitnessReminder
        default:.unknown(value)
        }
    }

    func encode(to encoder:Encoder) throws {
        var container=encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct FitnessCoachProposalDestination:Codable,Identifiable,Equatable,Hashable,Sendable {
    let kind:FitnessCoachProposalDestinationKind
    let target:String
    let label:String
    var id:String { "\(kind.rawValue):\(target)" }
}

enum FitnessCoachUndoStatus: String, Codable, Sendable {
    case undone
    case alreadyUndone = "already_undone"
    case conflict, invalid
}

struct FitnessCoachProposalUndo: Codable, Equatable, Sendable {
    let status: FitnessCoachUndoStatus
    let message: String
    let affectedIds: [String]

    var succeeded: Bool { status == .undone || status == .alreadyUndone }
}

enum FitnessCoachFeedback: String, Codable, CaseIterable, Identifiable, Sendable {
    case accepted, rejected
    case triedWorked = "tried_worked"
    case triedTooHard = "tried_too_hard"
    case triedTooHungry = "tried_too_hungry"
    case unavailable, disliked
    case analysisInaccurate = "analysis_inaccurate"
    case other

    var id: String { rawValue }
    var label: String {
        switch self {
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case .triedWorked: "Tried — worked"
        case .triedTooHard: "Tried — too hard"
        case .triedTooHungry: "Tried — too hungry"
        case .unavailable: "Could not do it"
        case .disliked: "Disliked"
        case .analysisInaccurate: "Evidence looked wrong"
        case .other: "Other"
        }
    }
}

struct FitnessCoachFeedbackRequest: Codable, Equatable, Sendable {
    let feedback: FitnessCoachFeedback
}

struct FitnessCoachRecommendation: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let revision: Int?
    let createdAt: String?
    let updatedAt: String?
    let recommendationType: String
    let recommendationText: String
    let evidence: [FitnessCoachEvidence]?
    let findingReferences: [String]?
    let expectedEffect: JSONValue?
    let status: String
    let userFeedback: FitnessCoachFeedback?
    let followedState: String?
    let outcomeReview: String?
    let modelProvider: String?
    let modelId: String?
}

struct FitnessCoachChatMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: FitnessCoachRole
    let content: String
    let evidence: [FitnessCoachEvidence]
    let recommendation: FitnessCoachRecommendation?
    let proposal: FitnessCoachProposal?
    let memoryCandidates: [FitnessCoachMemoryCandidate]
    var proposalDecision: FitnessCoachProposalDecision?
    var proposalUndo: FitnessCoachProposalUndo?

    init(
        id: UUID = UUID(),role: FitnessCoachRole,content: String,
        evidence: [FitnessCoachEvidence] = [],recommendation: FitnessCoachRecommendation? = nil,
        proposal: FitnessCoachProposal? = nil,memoryCandidates: [FitnessCoachMemoryCandidate] = [],
        proposalDecision: FitnessCoachProposalDecision? = nil,
        proposalUndo: FitnessCoachProposalUndo? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.evidence = evidence
        self.recommendation = recommendation
        self.proposal = proposal
        self.memoryCandidates = memoryCandidates
        self.proposalDecision = proposalDecision
        self.proposalUndo = proposalUndo
    }
}

struct FitnessCoachTrainingWeekProposal:Equatable,Sendable {
    let name:String?
    let purpose:String?
    let startsOn:String?
    let sessions:[FitnessCoachTrainingWeekSession]
    private let sourceSessionCount:Int
    private let sourceSessionsAreObjects:Bool

    init?(payload:[String:JSONValue]) {
        guard case .array(let rawSessions)=payload["sessions"],!rawSessions.isEmpty else { return nil }
        let objects=rawSessions.compactMap { value -> [String:JSONValue]? in
            if case .object(let object)=value { return object }
            return nil
        }
        sessions=objects.enumerated().compactMap {
            FitnessCoachTrainingWeekSession(index:$0.offset,payload:$0.element)
        }
        sourceSessionCount=rawSessions.count
        sourceSessionsAreObjects=objects.count == rawSessions.count
        name=payload.string("name")
        purpose=payload.string("purpose")
        startsOn=payload.string("starts_on")
    }

    var previewIsComplete:Bool {
        sourceSessionsAreObjects && (1...14).contains(sourceSessionCount)
            && sessions.count == sourceSessionCount
            && sessions.allSatisfy(\.previewIsComplete)
    }
}

struct FitnessCoachTrainingWeekSession:Identifiable,Equatable,Sendable {
    enum Workout:Equatable,Sendable {
        case run(FitnessCoachRunProposal)
        case strength(FitnessCoachStrengthProposal)
    }

    let id:String
    let title:String
    let sportKey:String
    let scheduledDate:String
    let workout:Workout

    init?(index:Int,payload:[String:JSONValue]) {
        guard let title=payload.string("title"),
              let sport=payload.string("sport_key"),
              let date=payload.string("scheduled_date") else { return nil }
        switch sport {
        case "running":
            guard let run=FitnessCoachRunProposal(payload:payload) else { return nil }
            workout = .run(run)
        case "strength":
            guard let strength=FitnessCoachStrengthProposal(payload:payload) else { return nil }
            workout = .strength(strength)
        default:return nil
        }
        self.title=title
        sportKey=sport
        scheduledDate=date
        id="\(date)|\(index)|\(title)"
    }

    var previewIsComplete:Bool {
        switch workout {
        case .run(let value):value.flattenedSteps.complete
        case .strength(let value):value.previewIsComplete
        }
    }
}

struct FitnessCoachRunProposal: Equatable, Sendable {
    let title: String?
    let purpose: String?
    let scheduledStartUtc: String?
    let scheduledDate: String?
    let estimatedDurationS: Double?
    let estimatedDistanceM: Double?
    let expectedDifficulty: String?
    let routeAssumption: String?
    let terrainAssumption: String?
    let goalReason: String?
    let steps: [FitnessCoachRunStep]
    let cues: [FitnessCoachRunCue]
    let garminLimitations: [String]

    init?(payload: [String: JSONValue]) {
        let steps = payload.objectArray("steps").compactMap(FitnessCoachRunStep.init(payload:))
        guard !steps.isEmpty else { return nil }
        title = payload.string("title")
        purpose = payload.string("purpose")
        scheduledStartUtc = payload.string("scheduled_start_utc")
        scheduledDate = payload.string("scheduled_date")
        estimatedDurationS = payload.number("estimated_duration_s") ?? payload.number("expected_duration_s")
        estimatedDistanceM = payload.number("estimated_distance_m") ?? payload.number("expected_distance_m")
        expectedDifficulty = payload.string("expected_difficulty")
        routeAssumption = payload.string("route_assumption")
        terrainAssumption = payload.string("terrain_assumption")
        goalReason = payload.string("goal_reason")
        self.steps = steps
        let cueObjects = payload.objectArray("cues") + payload.objectArray("kilometre_cues")
        cues = cueObjects.compactMap(FitnessCoachRunCue.init(payload:))
        garminLimitations = payload.stringArray("garmin_limitations")
    }

    var flattenedSteps: (rows: [FitnessCoachRunStepRow],complete: Bool) {
        var rows: [FitnessCoachRunStepRow] = []
        var complete = true
        func visit(_ values: [FitnessCoachRunStep],depth: Int,parent: String) {
            if depth > 4 { if !values.isEmpty { complete = false }; return }
            for (index,value) in values.enumerated() {
                guard rows.count < 60 else { complete = false; return }
                let path = parent.isEmpty ? "\(index + 1)" : "\(parent).\(index + 1)"
                rows.append(.init(id: path,path: path,depth: depth,step: value))
                visit(value.children,depth: depth + 1,parent: path)
            }
        }
        visit(steps,depth: 0,parent: "")
        return (rows,complete)
    }
}

struct FitnessCoachRunStep: Equatable, Sendable {
    let displayName: String?
    let durationType: String?
    let durationValue: Double?
    let repeatCount: Int?
    let targetType: String?
    let targetLow: Double?
    let targetHigh: Double?
    let targetUnit: String?
    let instructionText: String?
    let mentalCueText: String?
    let spokenCueText: String?
    let children: [FitnessCoachRunStep]

    init?(payload: [String: JSONValue]) {
        displayName = payload.string("display_name") ?? payload.string("name")
        durationType = payload.string("duration_type")
        durationValue = payload.number("duration_value")
        repeatCount = payload.integer("repeat_count")
        targetType = payload.string("target_type")
        targetLow = payload.number("target_low")
        targetHigh = payload.number("target_high")
        targetUnit = payload.string("target_unit")
        instructionText = payload.string("instruction_text")
        mentalCueText = payload.string("mental_cue_text")
        spokenCueText = payload.string("spoken_cue_text")
        children = payload.objectArray("children").compactMap(FitnessCoachRunStep.init(payload:))
        guard displayName != nil || durationType != nil || !children.isEmpty else { return nil }
    }
}

struct FitnessCoachRunStepRow: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let depth: Int
    let step: FitnessCoachRunStep
}

struct FitnessCoachRunCue: Identifiable, Equatable, Sendable {
    let id: String
    let kilometre: Int?
    let offsetS: Double?
    let distanceM: Double?
    let instruction: String?
    let thought: String?

    init?(payload: [String: JSONValue]) {
        kilometre = payload.integer("kilometre") ?? payload.integer("km")
        offsetS = payload.number("offset_s")
        distanceM = payload.number("distance_m")
        instruction = payload.string("instruction_text") ?? payload.string("instruction")
        thought = payload.string("mental_cue_text") ?? payload.string("spoken_cue_text") ?? payload.string("cue")
        guard instruction != nil || thought != nil else { return nil }
        let pieces: [String?] = [
            kilometre.map { String($0) },offsetS.map { String($0) },distanceM.map { String($0) },
            instruction,thought,
        ]
        id = pieces.compactMap { $0 }.joined(separator: "|")
    }
}

struct FitnessCoachStrengthProposal: Equatable, Sendable {
    let title: String?
    let purpose: String?
    let scheduledStartUtc: String?
    let scheduledDate: String?
    let estimatedDurationS: Double?
    let location: String?
    let goalReason: String?
    let exercises: [FitnessCoachStrengthExercise]

    init?(payload: [String: JSONValue]) {
        let values = payload.objectArray("exercises").compactMap(FitnessCoachStrengthExercise.init(payload:))
        guard !values.isEmpty else { return nil }
        title = payload.string("title")
        purpose = payload.string("purpose")
        scheduledStartUtc = payload.string("scheduled_start_utc")
        scheduledDate = payload.string("scheduled_date")
        estimatedDurationS = payload.number("estimated_duration_s") ?? payload.number("expected_duration_s")
        location = payload.string("location")
        goalReason = payload.string("goal_reason")
        exercises = values
    }

    var previewIsComplete: Bool {
        exercises.count <= 24
            && exercises.allSatisfy { exercise in
                exercise.sets.count <= 12 && exercise.sets.allSatisfy { $0.components.count <= 12 }
            }
    }
}

struct FitnessCoachStrengthExercise: Identifiable, Equatable, Sendable {
    let id: String
    let exerciseId: String?
    let exerciseName: String
    let setupId: String?
    let setupName: String?
    let reason: String?
    let substitutionReason: String?
    let sets: [FitnessCoachStrengthSet]

    init?(payload: [String: JSONValue]) {
        exerciseId = payload.string("exercise_id")
        guard let name = payload.string("exercise_name") ?? payload.string("name") else { return nil }
        exerciseName = name
        setupId = payload.string("setup_id") ?? payload.string("exercise_setup_id")
        setupName = payload.string("setup_name")
        reason = payload.string("reason") ?? payload.string("instruction")
        substitutionReason = payload.string("substitution_reason")
        sets = payload.objectArray("sets").compactMap(FitnessCoachStrengthSet.init(payload:))
        id = exerciseId ?? "\(name)|\(setupId ?? setupName ?? "")"
    }
}

struct FitnessCoachStrengthSet: Identifiable, Equatable, Sendable {
    let id: UUID
    let trainingRole: String?
    let structureType: String?
    let loadMode: String?
    let loadUnit: String?
    let loadMin: Double?
    let loadMax: Double?
    let repsMin: Int?
    let repsMax: Int?
    let rirMin: Double?
    let rirMax: Double?
    let rpeMin: Double?
    let rpeMax: Double?
    let restS: Double?
    let instruction: String?
    let componentCount: Int?
    let components: [FitnessCoachStrengthComponent]

    init?(payload: [String: JSONValue]) {
        id = UUID()
        trainingRole = payload.string("training_role")
        structureType = payload.string("structure_type")
        loadMode = payload.string("load_entry_mode") ?? payload.string("load_mode")
        loadUnit = payload.string("load_unit")
        let load = payload.number("load_value")
        loadMin = payload.number("load_min") ?? load
        loadMax = payload.number("load_max") ?? load
        let reps = payload.integer("reps") ?? payload.integer("reps_target")
        repsMin = payload.integer("reps_min") ?? reps
        repsMax = payload.integer("reps_max") ?? reps
        let rir = payload.number("rir")
        rirMin = payload.number("rir_min") ?? rir
        rirMax = payload.number("rir_max") ?? rir
        let rpe = payload.number("rpe")
        rpeMin = payload.number("rpe_min") ?? rpe
        rpeMax = payload.number("rpe_max") ?? rpe
        restS = payload.number("rest_s") ?? payload.number("rest_seconds")
        instruction = payload.string("instruction") ?? payload.string("notes")
        componentCount = payload.integer("component_count")
        components = payload.objectArray("components").compactMap(FitnessCoachStrengthComponent.init(payload:))
        guard trainingRole != nil || repsMin != nil || loadMin != nil || !components.isEmpty else { return nil }
    }
}

struct FitnessCoachStrengthComponent: Identifiable, Equatable, Sendable {
    let id: UUID
    let load: Double?
    let reps: Int?
    let rir: Double?
    let rpe: Double?
    let instruction: String?

    init?(payload: [String: JSONValue]) {
        id = UUID()
        load = payload.number("load_value") ?? payload.number("load")
        reps = payload.integer("reps") ?? payload.integer("reps_target")
        rir = payload.number("rir")
        rpe = payload.number("rpe")
        instruction = payload.string("instruction") ?? payload.string("notes")
        guard load != nil || reps != nil || instruction != nil else { return nil }
    }
}

private extension Dictionary where Key == String,Value == JSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key],!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    func number(_ key: String) -> Double? {
        switch self[key] {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
    func integer(_ key: String) -> Int? {
        switch self[key] {
        case .int(let value): value
        case .double(let value) where value.rounded() == value: Int(value)
        default: nil
        }
    }
    func objectArray(_ key: String) -> [[String: JSONValue]] {
        guard case .array(let values) = self[key] else { return [] }
        return values.compactMap { value in if case .object(let object) = value { return object }; return nil }
    }
    func stringArray(_ key: String) -> [String] {
        guard case .array(let values) = self[key] else { return [] }
        return values.compactMap { value in if case .string(let text) = value { return text }; return nil }
    }
}
