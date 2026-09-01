import Foundation
import UIKit
import os

private func loadDashboardCachedActiveWorkout() async throws -> FitnessStrengthSession? {
    try await FitnessRepository.shared.activeWorkout()
}

private func loadDashboardCachedPlannedSessions() async throws -> [FitnessPlannedSession] {
    try await FitnessRepository.shared.plannedSessions()
}

// MARK: - DashboardViewModel

/// ViewModel for the Dashboard screen. Fetches one consistent at-a-glance snapshot
/// and publishes it for the DashboardView to display.
@MainActor
final class DashboardViewModel: ObservableObject {
    private static let logger = Logger(
        subsystem:"org.example.hausklar",category:"DashboardViewModel"
    )

    // MARK: - Published Properties

    @Published var todaysEvents: [CalendarEventDTO] = []
    @Published var tasksDueToday: [TaskDTO] = []
    @Published var actionableTasks: [TaskDTO] = []
    @Published var activeRoutines: [ActiveRoutineDTO] = []
    @Published var familyMembers: [FamilyMemberDTO] = []
    @Published var mealPlans: [MealPlanDTO] = []
    @Published var activeNaps: [NapDTO] = []
    @Published var medicineAttention: [GlanceMedicineDTO] = []
    @Published var dogStatus: DogStatusDTO?
    @Published var activeIllnesses: [ActiveIllnessDTO] = []
    @Published var childNames: [String: String] = [:]
    @Published var illnessReadings: [String: [TemperatureReadingDTO]] = [:]  // illnessId -> readings
    @Published var dailyBriefing: DailyBriefingDTO?
    @Published var childBriefingRows: [ChildDailyBriefingRow] = []
    @Published var tomorrowCard: TomorrowCardDTO?
    @Published var memories: [PhotoMemoryDTO] = []
    @Published var memoryImages: [String: UIImage] = [:]  // assetId -> thumbnail
    @Published var insights: [InsightDTO] = []
    @Published var insightBusy: String?
    @Published var insightNotice: String?
    @Published var prepSuggestions: [PrepPackSuggestionDTO] = []
    @Published var prepBusy: String?
    @Published var prepNotice: String?
    @Published var prepNoticeIsError = false
    @Published var coordinationError: String?
    @Published var coordinationBusy: String?
    @Published var financeAction: TodayFinanceActionDTO?
    @Published var financeActionUnavailable = false
    @Published var fitnessTodayCard: FitnessTodayCardDTO?
    @Published var facilityQuickFact: FacilityQuickFactDTO?
    @Published var upcomingHomework: [TodayHomeworkDTO] = []
    @Published var upcomingPresents: [TodayPresentDTO] = []
    @Published private(set) var unavailableFeeds: Set<String> = []
    @Published var eventsUnavailable = false
    @Published var tasksUnavailable = false
    @Published var recentlyCompletedTask: TaskDTO?
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Private

    private let apiClient: APIClient
    private let imageCache = DecodedImageCache.shared
    private let loadCachedActiveWorkout: () async throws -> FitnessStrengthSession?
    private let loadCachedPlannedSessions: () async throws -> [FitnessPlannedSession]
    private let now: () -> Date
    private var medicineSnapshotDate: String?
    private var napSnapshotDate: String?
    private var dayScopedSnapshotDate: String?

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601FallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private static let dayScopedFeeds: Set<String> = [
        "events", "naps", "medicine", "routines", "meals", "dog",
        "coordination", "prep_suggestions", "birthdays", "weather",
        "facility_quick_fact",
    ]

    init(
        apiClient: APIClient = .shared,
        loadCachedActiveWorkout: @escaping () async throws -> FitnessStrengthSession?
            = loadDashboardCachedActiveWorkout,
        loadCachedPlannedSessions: @escaping () async throws -> [FitnessPlannedSession]
            = loadDashboardCachedPlannedSessions,
        now: @escaping () -> Date = Date.init
    ) {
        self.apiClient = apiClient
        self.loadCachedActiveWorkout = loadCachedActiveWorkout
        self.loadCachedPlannedSessions = loadCachedPlannedSessions
        self.now = now
    }

    // MARK: - Actions

    /// Loads the complete dashboard from one stable server snapshot.
    func loadDashboard(fitnessEnabled: Bool = true) async {
        let glanceOwner = GlanceStore.activeIdentity
        let referenceDate = now()
        let today = Self.dateOnlyFormatter.string(from: referenceDate)
        // A long-lived Today view can cross midnight. Durable family context may
        // age quietly, but civil-day labels must not carry into the next day.
        if let snapshotDate = dayScopedSnapshotDate, snapshotDate != today {
            clearDayScopedState(for: today)
            dayScopedSnapshotDate = nil
        }
        todaysEvents = eventsForDay(todaysEvents, referenceDate: referenceDate)
        if napSnapshotDate != today {
            activeNaps = []
        }
        if medicineSnapshotDate != today {
            medicineAttention = []
        }
        if fitnessTodayCard?.date != today {
            fitnessTodayCard = nil
        }
        isLoading = true
        errorMessage = nil
        let fitnessTask: Task<FitnessTodayCardDTO?, Never>?
        if fitnessEnabled,let identity = FitnessDatabase.shared.activeIdentity {
            do {
                let lease=try FitnessDatabase.shared.lease(for:identity)
                fitnessTask = Task {
                    do {
                        return try await FitnessDatabase.shared.withLease(lease) {
                            await self.fetchFitnessTodayCard()
                        }
                    } catch is CancellationError {
                        return nil
                    } catch {
                        Self.logger.error(
                            "Optional Fitness dashboard card failed: \(error.localizedDescription, privacy:.private)"
                        )
                        return nil
                    }
                }
            } catch {
                Self.logger.error(
                    "Fitness dashboard lease could not be created: \(error.localizedDescription, privacy:.private)"
                )
                fitnessTask=nil
            }
        } else {
            fitnessTask = nil
        }
        do {
            let response: APIClient.ProvenancedGet<TodayDashboardDTO> = try await apiClient.getWithProvenance(
                "/briefing/dashboard",
                queryItems: [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)],
                bypassCache: true
            )
            let dashboard = response.value
            let usedStaleFallback = response.provenance == .staleFallback
            var unavailable = Set(dashboard.unavailable)
            if usedStaleFallback {
                // Ordinary family context may age quietly offline. Active nap and
                // medicine timing are current-state claims and must fail closed.
                unavailable.insert("medicine")
                unavailable.insert("naps")
            }
            // Most of yesterday's snapshot is still useful context. Day-scoped
            // feeds are suppressed silently instead of relabelled as today.
            if dashboard.date != today {
                unavailable.formUnion(Self.dayScopedFeeds)
                clearDayScopedState(for: today)
                dayScopedSnapshotDate = nil
            } else {
                dayScopedSnapshotDate = today
            }
            unavailableFeeds = unavailable
            eventsUnavailable = unavailable.contains("events")
            tasksUnavailable = unavailable.contains("tasks")
            // Optional feeds fail independently. Never replace useful cached rows
            // with the backend's empty fallback or describe that fallback as truth.
            if !eventsUnavailable {
                todaysEvents = eventsForDay(
                    dashboard.events,
                    referenceDate: referenceDate
                ).sorted { $0.startTime < $1.startTime }
            }
            if !tasksUnavailable {
                tasksDueToday = filterTasksDueToday(dashboard.tasks, referenceDate: referenceDate)
                actionableTasks = dashboard.tasks.sorted(by: taskNeedsAttentionFirst)
            }
            if !unavailable.contains("routines") { activeRoutines = dashboard.routines }
            if !unavailable.contains("family_members") { familyMembers = dashboard.familyMembers }
            if !unavailable.contains("meals") { mealPlans = dashboard.meals }
            if !unavailable.contains("naps") {
                activeNaps = dashboard.naps
                napSnapshotDate = dashboard.date
            } else if dashboard.date != today || usedStaleFallback {
                activeNaps = []
                napSnapshotDate = nil
            }
            if !unavailable.contains("medicine") {
                medicineAttention = dashboard.medicine
                medicineSnapshotDate = dashboard.date
            } else {
                // Timing status is a safety decision, not ordinary cached content.
                // Another adult may have recorded a dose since this snapshot.
                medicineAttention = []
                medicineSnapshotDate = nil
            }
            if !unavailable.contains("dog") { dogStatus = dashboard.dog }
            if !unavailable.contains("illnesses") { activeIllnesses = dashboard.illnesses }
            if !unavailable.contains("illness_readings") {
                illnessReadings = dashboard.illnessReadings
            }
            childNames = Dictionary(
                uniqueKeysWithValues: familyMembers
                    .filter { $0.memberType == "child" }
                    .map { ($0.id, $0.name) }
            )
            childBriefingRows = buildChildBriefingRows(
                routines: activeRoutines,
                familyMembers: familyMembers
            )
            if !unavailable.contains("coordination") { tomorrowCard = dashboard.coordination }
            if !unavailable.contains("memories") {
                memories = dashboard.memories
                memoryImages.removeAll(keepingCapacity: true)
            }
            if !unavailable.contains("insights") { insights = dashboard.insights }
            if !unavailable.contains("prep_suggestions") {
                prepSuggestions = dashboard.prepSuggestions
            }
            if !unavailable.contains("finance_action") { financeAction = dashboard.financeAction }
            if !unavailable.contains("facility_quick_fact") {
                facilityQuickFact = dashboard.facilityQuickFact
            }
            if !unavailable.contains("homework") { upcomingHomework = dashboard.homework }
            if !unavailable.contains("presents") { upcomingPresents = dashboard.presents ?? [] }
            financeActionUnavailable = unavailable.contains("finance_action")
            let birthdays = unavailable.contains("birthdays")
                ? dailyBriefing?.upcomingBirthdays ?? []
                : dashboard.birthdays.map {
                    BriefingBirthdayDTO(
                        personName: $0.personName,
                        dateOfBirth: $0.dateOfBirth,
                        daysUntil: $0.daysUntil,
                        turningAge: $0.turningAge
                    )
                }
            let weather = unavailable.contains("weather")
                ? dailyBriefing?.weather
                : dashboard.weather
            dailyBriefing = DailyBriefingDTO(
                date: dashboard.date == today ? dashboard.date : today,
                generatedAt: dashboard.generatedAt,
                calendarEvents: [],
                tasksDue: [],
                upcomingBirthdays: birthdays,
                weather: weather
            )
            // Do not replace the widget's last trustworthy core snapshot with
            // empty fallback arrays from a partially failed dashboard response.
            let glanceFeeds: Set<String> = [
                "events", "tasks", "meals", "medicine", "coordination",
                "memories", "family_members",
            ]
            if dashboard.date == today && unavailable.isDisjoint(with: glanceFeeds) {
                GlanceStore.save(makeGlance(from: dashboard), for: glanceOwner)
                WidgetReloader.shared.requestReload(after: 0.5)
            }
        } catch {
            unavailableFeeds.formUnion(["events", "tasks", "medicine", "illnesses", "naps"])
            eventsUnavailable = true
            tasksUnavailable = true
            activeNaps = []
            napSnapshotDate = nil
            medicineAttention = []
            medicineSnapshotDate = nil
            // Keep an already useful day on screen without turning a routine
            // refresh failure into family-facing noise.
            if todaysEvents.isEmpty && actionableTasks.isEmpty
                && activeNaps.isEmpty && activeIllnesses.isEmpty {
                errorMessage = "Today’s plan could not be loaded. Pull to try again.".localized
            }
        }
        // The private Fitness card is optional and independently cached. Do not
        // keep the whole family dashboard in a loading state while it resolves.
        isLoading = false
        // Fitness is intentionally independent of the family briefing. Its
        // owner-only cache keeps the next action useful when the API is offline.
        fitnessTodayCard = await fitnessTask?.value
    }

    /// Refreshes only the owner-private Fitness card after a Fitness mutation.
    /// The family briefing is intentionally left alone: refetching every Today
    /// feed after logging food is both slower and unnecessary.
    func refreshFitnessTodayCard() async {
        guard let identity = FitnessDatabase.shared.activeIdentity else {
            fitnessTodayCard = nil
            return
        }
        do {
            let lease = try FitnessDatabase.shared.lease(for: identity)
            let card = try await FitnessDatabase.shared.withLease(lease) {
                try await self.requestFitnessTodayCard()
            }
            guard FitnessDatabase.shared.activeIdentity == identity,
                  card.date == Self.dateOnlyFormatter.string(from: now()) else { return }
            fitnessTodayCard = card
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error(
                "Fitness Today card refresh failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func fetchFitnessTodayCard() async -> FitnessTodayCardDTO? {
        let today = Self.dateOnlyFormatter.string(from: now())
        do {
            let card = try await requestFitnessTodayCard()
            guard card.date == today else { return await cachedFitnessTodayCard() }
            return card
        } catch {
            return await cachedFitnessTodayCard()
        }
    }

    private func requestFitnessTodayCard() async throws -> FitnessTodayCardDTO {
        try await apiClient.get(
            "/fitness/today-card",
            queryItems: [
                URLQueryItem(
                    name: "date",
                    value: Self.dateOnlyFormatter.string(from: now())
                )
            ],
            bypassCache: true
        )
    }

    private func cachedFitnessTodayCard() async -> FitnessTodayCardDTO? {
        let now = now()
        let today = Self.dateOnlyFormatter.string(from: now)
        let cachedActive: FitnessStrengthSession?
        do {
            cachedActive = try await loadCachedActiveWorkout()
        } catch {
            Self.logger.error(
                "Cached active workout could not be read: \(error.localizedDescription, privacy:.private)"
            )
            cachedActive = nil
        }
        if let active = cachedActive {
            return FitnessTodayCardDTO(
                date: today,
                hasCompletedActivityToday: false,
                session: FitnessTodayCardSessionDTO(
                    id: active.id,
                    kind: "active_activity",
                    title: active.title,
                    sportKey: "strength",
                    status: "in_progress",
                    startsAt: ISODateParser.stringNoFractional(from: active.startedAt),
                    scheduledDate: today,
                    durationMinutes: nil,
                    movable: false
                ),
                primaryAction: FitnessTodayCardActionDTO(
                    kind: "resume_activity",
                    label: "Resume",
                    destination: .plan,
                    targetId: active.id
                ),
                secondaryAction: nil,
                nutrition: nil
            )
        }

        let plans:[FitnessPlannedSession]
        do {
            plans=try await loadCachedPlannedSessions()
        } catch {
            Self.logger.error(
                "Cached planned sessions could not be read: \(error.localizedDescription, privacy:.private)"
            )
            return nil
        }
        guard let plan = plans
                .filter({ cachedPlanIsForToday($0, today: today, now: now) })
                .sorted(by: cachedPlanComesFirst)
                .first else {
            return FitnessTodayCardDTO(
                date:today,
                hasCompletedActivityToday:false,
                session:nil,
                primaryAction:FitnessTodayCardActionDTO(
                    kind:"start_strength",
                    label:"Start workout",
                    destination:.plan,
                    targetId:nil
                ),
                secondaryAction:nil,
                nutrition:nil
            )
        }
        let isStrength = plan.sportKey == "strength"
        return FitnessTodayCardDTO(
            date: today,
            hasCompletedActivityToday: false,
            session: FitnessTodayCardSessionDTO(
                id: plan.id,
                kind: "planned_session",
                title: plan.title,
                sportKey: plan.sportKey,
                status: plan.status,
                startsAt: plan.scheduledStart.map {
                    ISODateParser.stringNoFractional(from: $0)
                },
                scheduledDate: plan.scheduledDate ?? plan.plannedFor.map {
                    Self.dateOnlyFormatter.string(from: $0)
                },
                durationMinutes: plan.expectedDurationSeconds.map { max(0, Int($0 / 60)) },
                movable: plan.movable
            ),
            primaryAction: FitnessTodayCardActionDTO(
                kind: isStrength ? "start_session" : "open_session",
                label: isStrength ? "Start" : "Open",
                destination: .plan,
                targetId: plan.id
            ),
            secondaryAction: plan.movable
                ? FitnessTodayCardActionDTO(
                    kind: "move_session",
                    label: "Move",
                    destination: .plan,
                    targetId: plan.id
                )
                : nil,
            nutrition: nil
        )
    }

    private func cachedPlanIsForToday(
        _ plan: FitnessPlannedSession,
        today: String,
        now: Date
    ) -> Bool {
        guard plan.isStartable else { return false }
        if plan.scheduledDate == today { return true }
        if let scheduledStart = plan.scheduledStart,
           Calendar.current.isDate(scheduledStart, inSameDayAs: now) {
            return true
        }
        if let plannedFor = plan.plannedFor,
           Calendar.current.isDate(plannedFor, inSameDayAs: now) {
            return true
        }
        return false
    }

    private func cachedPlanComesFirst(
        _ lhs: FitnessPlannedSession,
        _ rhs: FitnessPlannedSession
    ) -> Bool {
        let statusPriority = ["in_progress": 0, "accepted": 1, "scheduled": 2]
        let lhsPriority = statusPriority[lhs.status] ?? 3
        let rhsPriority = statusPriority[rhs.status] ?? 3
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        let lhsDate = lhs.scheduledStart ?? lhs.plannedFor ?? .distantFuture
        let rhsDate = rhs.scheduledStart ?? rhs.plannedFor ?? .distantFuture
        if lhsDate != rhsDate { return lhsDate < rhsDate }
        return lhs.id < rhs.id
    }

    func acknowledgeTomorrow() async {
        guard let card = tomorrowCard else { return }
        coordinationBusy = "ack"
        coordinationError = nil
        defer { coordinationBusy = nil }
        do {
            try await apiClient.postNoResponse(
                "/coordination/tomorrow/ack",
                body: TomorrowAcknowledgementRequest(targetDate: card.targetDate)
            )
            tomorrowCard = TomorrowCardDTO(
                targetDate: card.targetDate, visible: card.visible, acknowledged: true,
                events: card.events, tasks: card.tasks, loadPrompt: card.loadPrompt
            )
            HapticManager.success()
        } catch {
            coordinationError = "Tomorrow’s plan could not be confirmed.".localized
            HapticManager.error()
        }
    }

    func assignLoad(to member: FamilyMemberDTO) async {
        guard let card = tomorrowCard, let prompt = card.loadPrompt else { return }
        coordinationBusy = member.id
        coordinationError = nil
        defer { coordinationBusy = nil }
        do {
            try await apiClient.postNoResponse(
                "/coordination/load/\(prompt.taskId)/assign",
                body: LoadAssignmentRequest(assigneeId: member.id)
            )
            tomorrowCard = TomorrowCardDTO(
                targetDate: card.targetDate, visible: card.visible, acknowledged: card.acknowledged,
                events: card.events, tasks: card.tasks, loadPrompt: nil
            )
            HapticManager.success()
        } catch {
            coordinationError = "That responsibility could not be assigned.".localized
            HapticManager.error()
        }
    }

    func deferLoad() async {
        guard let card = tomorrowCard, let prompt = card.loadPrompt else { return }
        coordinationBusy = "later"
        coordinationError = nil
        defer { coordinationBusy = nil }
        do {
            try await apiClient.postNoResponse("/coordination/load/\(prompt.taskId)/later", body: EmptyBody())
            tomorrowCard = TomorrowCardDTO(
                targetDate: card.targetDate, visible: card.visible, acknowledged: card.acknowledged,
                events: card.events, tasks: card.tasks, loadPrompt: nil
            )
        } catch {
            coordinationError = "That prompt could not be put aside.".localized
        }
    }

    // MARK: - Private Helpers

    private func clearDayScopedState(for today: String) {
        todaysEvents = []
        activeNaps = []
        napSnapshotDate = nil
        medicineAttention = []
        medicineSnapshotDate = nil
        activeRoutines = []
        childBriefingRows = []
        mealPlans = []
        dogStatus = nil
        tomorrowCard = nil
        prepSuggestions = []
        prepNotice = nil
        facilityQuickFact = nil
        if let briefing = dailyBriefing {
            dailyBriefing = DailyBriefingDTO(
                date: today,
                generatedAt: briefing.generatedAt,
                calendarEvents: [],
                tasksDue: [],
                upcomingBirthdays: [],
                weather: nil
            )
        }
    }

    func loadMemoryImage(for memory: PhotoMemoryDTO) async {
        guard memoryImages[memory.assetId] == nil,
            memories.prefix(5).contains(where: { $0.assetId == memory.assetId }),
            let lease = imageCache.currentLease()
        else { return }
        let client = apiClient
        let image = await imageCache.image(
            kind: .photoArchiveThumbnail,
            resourceID: memory.assetId,
            maximumPixelSize: 800,
            lease: lease
        ) {
            try await client.downloadData(
                "/photos/\(memory.assetId)/thumbnail",
                policy: .image(maximumBytes: 8 * 1_024 * 1_024),
                queryItems: [URLQueryItem(name: "size", value: "preview")]
            )
        }
        guard !Task.isCancelled,
            memories.prefix(5).contains(where: { $0.assetId == memory.assetId }),
            let image
        else { return }
        memoryImages[memory.assetId] = image
    }

    func releaseMemoryImage(for assetID: String) {
        memoryImages[assetID] = nil
    }

    private func makeGlance(from dashboard: TodayDashboardDTO) -> GlanceDTO {
        let firstTomorrow = dashboard.coordination?.events.first
        return GlanceDTO(
            generatedAt: dashboard.generatedAt,
            date: dashboard.date,
            events: dashboard.events.prefix(10).map {
                var participantIDs = Set($0.familyMemberIds ?? [])
                if let assignedTo = $0.assignedTo { participantIDs.insert(assignedTo) }
                let participantNames = dashboard.familyMembers
                    .filter { participantIDs.contains($0.id) }
                    .map(\.name)
                return GlanceEventDTO(
                    id: $0.id,
                    title: $0.title,
                    startTime: $0.startTime,
                    allDay: $0.allDay,
                    personName: participantNames.isEmpty ? nil : participantNames.joined(separator: " & ")
                )
            },
            tasksDue: tasksDueToday.prefix(10).map {
                GlanceTaskDTO(id: $0.id, title: $0.title, dueDate: $0.dueDate)
            },
            dinner: dashboard.meals.first(where: { $0.mealType == "dinner" }).flatMap {
                ($0.mealName ?? $0.notes).map { GlanceDinnerDTO(title: $0) }
            },
            medicine: dashboard.medicine,
            tomorrow: GlanceTomorrowDTO(
                firstEvent: firstTomorrow.map {
                    GlanceTomorrowEventDTO(title: $0.title, startTime: $0.startTime, allDay: $0.allDay)
                },
                eventCount: dashboard.coordination?.events.count ?? 0
            ),
            memory: dashboard.memories.first.flatMap { memory in
                memory.takenAt.map {
                    GlanceMemoryDTO(assetId: memory.assetId, takenAt: $0, yearsAgo: memory.yearsAgo)
                }
            }
        )
    }

    func applyPrepPack(_ suggestion: PrepPackSuggestionDTO) async {
        prepBusy = suggestion.id
        prepNotice = nil
        prepNoticeIsError = false
        defer { prepBusy = nil }
        do {
            let result: PrepPackApplyResponseDTO = try await apiClient.post(
                "/prep-packs/apply",
                body: prepAction(for: suggestion)
            )
            prepSuggestions.removeAll { $0.id == suggestion.id }
            insights.removeAll { $0.kind == "prep" }
            let format = result.taskCount == 1
                ? "%lld task added for %@.".localized
                : "%lld tasks added for %@.".localized
            prepNotice = String(
                format: format,
                Int64(result.taskCount),
                suggestion.eventTitle
            )
            HapticManager.success()
        } catch {
            prepNoticeIsError = true
            prepNotice = "The preparation tasks could not be added. Please try again.".localized
            HapticManager.error()
        }
    }

    func dismissPrepPack(_ suggestion: PrepPackSuggestionDTO) async {
        prepBusy = suggestion.id
        prepNotice = nil
        prepNoticeIsError = false
        defer { prepBusy = nil }
        do {
            let _: PrepPackStatusResponseDTO = try await apiClient.post(
                "/prep-packs/dismiss",
                body: prepAction(for: suggestion)
            )
            prepSuggestions.removeAll { $0.id == suggestion.id }
            HapticManager.selection()
        } catch {
            prepNoticeIsError = true
            prepNotice = "That suggestion could not be dismissed. Please try again.".localized
            HapticManager.error()
        }
    }

    private func prepAction(for suggestion: PrepPackSuggestionDTO) -> PrepPackActionRequest {
        PrepPackActionRequest(
            templateId: suggestion.templateId,
            eventId: suggestion.eventId,
            occurrenceStart: suggestion.occurrenceStart,
            timezone: TimeZone.current.identifier
        )
    }

    func dismissInsight(_ id: String) async {
        do {
            let _: InsightDismissResponseDTO = try await apiClient.post("/insights/\(id)/dismiss", body: EmptyBody())
            insights.removeAll { $0.id == id }
            HapticManager.success()
        } catch {
            HapticManager.error()
        }
    }

    func addInsightTask(_ insight: InsightDTO) async {
        insightBusy = insight.id
        insightNotice = nil
        defer { insightBusy = nil }
        do {
            let result: InsightTaskResponseDTO = try await apiClient.post(
                "/insights/\(insight.id)/add-task",
                body: EmptyBody()
            )
            insights.removeAll { $0.id == insight.id }
            insightNotice = String(format: "Task added: %@".localized, result.title)
            HapticManager.success()
        } catch {
            insightNotice = "The task could not be added. Please try again.".localized
            HapticManager.error()
        }
    }

    func completeTask(_ id: String) async {
        let completedTask = actionableTasks.first { $0.id == id }
        do {
            let _: TaskDTO = try await apiClient.patch("/tasks/\(id)/complete", body: EmptyBody())
            actionableTasks.removeAll { $0.id == id }
            tasksDueToday.removeAll { $0.id == id }
            recentlyCompletedTask = completedTask
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to complete task.".localized
        }
    }

    func undoTaskCompletion() async {
        guard let task = recentlyCompletedTask else { return }
        do {
            let reopened: TaskDTO = try await apiClient.patch(
                "/tasks/\(task.id)/reopen",
                body: EmptyBody()
            )
            actionableTasks.append(reopened)
            actionableTasks.sort(by: taskNeedsAttentionFirst)
            if filterTasksDueToday([reopened], referenceDate: Date()).isEmpty == false {
                tasksDueToday.append(reopened)
            }
            recentlyCompletedTask = nil
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "That task could not be reopened.".localized
        }
    }

    func memberName(for id: String?) -> String? {
        guard let id else { return nil }
        return familyMembers.first(where: { $0.id == id })?.name
    }

    // MARK: - Helpers

    /// Builds child-specific reminders from today's routine items.
    private func buildChildBriefingRows(
        routines: [ActiveRoutineDTO],
        familyMembers: [FamilyMemberDTO]
    ) -> [ChildDailyBriefingRow] {
        let children = familyMembers.filter { $0.memberType == "child" }

        return children
            .map { child in
                let childRoutines = routines
                    .filter { $0.personId == child.id }
                    .map(\.name)
                let hasPE = childRoutines.contains { name in
                    name.localizedCaseInsensitiveContains("pe")
                }
                let booksDueBack = childRoutines.contains { name in
                    let lowered = name.lowercased()
                    return lowered.contains("book") || lowered.contains("library")
                }

                let clubs = childRoutines.filter { name in
                    let lowered = name.lowercased()
                    return !lowered.contains("pe") && !lowered.contains("book") && !lowered.contains("library")
                }

                return ChildDailyBriefingRow(
                    childId: child.id,
                    childName: child.name,
                    clubs: Array(Set(clubs)).sorted(),
                    hasPE: hasPE,
                    booksDueBack: booksDueBack
                )
            }
            .filter { !$0.clubs.isEmpty || $0.hasPE || $0.booksDueBack }
            .sorted { $0.childName < $1.childName }
    }

    /// Filters tasks to only those due today or overdue (due before today).
    private func filterTasksDueToday(_ tasks: [TaskDTO], referenceDate: Date) -> [TaskDTO] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: referenceDate)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday

        return tasks.filter { task in
            guard let dueDateString = task.dueDate else { return false }

            // Try parsing as ISO 8601 datetime first
            if let dueDate = Self.iso8601Formatter.date(from: dueDateString) {
                return dueDate < startOfTomorrow
            }
            if let dueDate = Self.iso8601FallbackFormatter.date(from: dueDateString) {
                return dueDate < startOfTomorrow
            }
            // Try parsing as date-only string (yyyy-MM-dd)
            if let dueDate = Self.dateOnlyFormatter.date(from: dueDateString) {
                return dueDate <= startOfToday
            }
            return false
        }
    }

    /// The dashboard endpoint is cacheable, so enforce the semantic boundary
    /// locally before anything is labelled Today or Up next. Multi-day events
    /// are retained when they genuinely overlap the local civil day.
    private func eventsForDay(
        _ events: [CalendarEventDTO],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> [CalendarEventDTO] {
        guard let day = calendar.dateInterval(of: .day, for: referenceDate) else {
            return []
        }
        return events.filter { event in
            guard let start = eventBoundary(
                event.startTime,
                allDay: event.allDay,
                calendar: calendar
            ) else { return false }
            let end = event.endTime.flatMap {
                eventBoundary($0, allDay: event.allDay, calendar: calendar)
            }
            if let end, end > start {
                return start < day.end && end > day.start
            }
            return start >= day.start && start < day.end
        }
    }

    private func eventBoundary(
        _ value: String,
        allDay: Bool,
        calendar: Calendar
    ) -> Date? {
        if allDay, value.count == 10 {
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let year = Int(parts[0]),
                  let month = Int(parts[1]),
                  let day = Int(parts[2]) else { return nil }
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            return gregorian.date(from: DateComponents(
                timeZone: gregorian.timeZone,
                year: year,
                month: month,
                day: day
            ))
        }
        return ISODateParser.parse(value)
    }

    private func taskNeedsAttentionFirst(_ lhs: TaskDTO, _ rhs: TaskDTO) -> Bool {
        let leftDue = taskDueDate(lhs)
        let rightDue = taskDueDate(rhs)
        switch (leftDue, rightDue) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func taskDueDate(_ task: TaskDTO) -> Date? {
        guard let value = task.dueDate else { return nil }
        return Self.iso8601Formatter.date(from: value)
            ?? Self.iso8601FallbackFormatter.date(from: value)
            ?? Self.dateOnlyFormatter.date(from: value)
    }
}
