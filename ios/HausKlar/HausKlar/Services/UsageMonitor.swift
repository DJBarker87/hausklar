import Foundation

/// Stable, content-free surfaces that have been reviewed by the server.
enum UsageSurface: String, Sendable {
    case todayFacilities = "today_facilities"
    case calendarEvent = "calendar_event"
}

enum UsageControl: Sendable {
    case openCapture(AppTab)
    case openAdd(AppTab)
    case openSearch(AppTab)
    case openMore(AppTab)
    case openFitnessLog(AppTab)
    case openFitnessCoach(AppTab)
    case openSwimmingBooking(UsageSurface)

    fileprivate var descriptor: UsageEventDescriptor {
        switch self {
        case .openCapture(let tab):
            UsageEventDescriptor(module: "capture", action: "open_capture", surface: tab.rawValue)
        case .openAdd(let tab):
            UsageEventDescriptor(module: "capture", action: "open_add", surface: tab.rawValue)
        case .openSearch(let tab):
            UsageEventDescriptor(module: "search", action: "open_search", surface: tab.rawValue)
        case .openMore(let tab):
            UsageEventDescriptor(module: "navigation", action: "open_more", surface: tab.rawValue)
        case .openFitnessLog(let tab):
            UsageEventDescriptor(module: "fitness", action: "open_fitness_log", surface: tab.rawValue)
        case .openFitnessCoach(let tab):
            UsageEventDescriptor(module: "fitness", action: "open_fitness_coach", surface: tab.rawValue)
        case .openSwimmingBooking(let surface):
            UsageEventDescriptor(
                module: "facilities",
                action: "open_swimming_booking",
                surface: surface.rawValue,
                workflow: "book_swimming"
            )
        }
    }
}

enum UsageWorkflow: Sendable {
    case saveFoodLog
    case quickLogFood
    case saveMealLogs
    case logPlannedMeal
    case logMealTemplate
    case pullStrava
    case bookSwimming(UsageSurface)

    fileprivate var descriptor: UsageEventDescriptor {
        switch self {
        case .saveFoodLog:
            UsageEventDescriptor(
                module: "fitness", action: "save_food_log", surface: "fitness_food_editor",
                workflow: "log_food"
            )
        case .quickLogFood:
            UsageEventDescriptor(
                module: "fitness", action: "quick_log_food", surface: "fitness_log",
                workflow: "log_food"
            )
        case .saveMealLogs:
            UsageEventDescriptor(
                module: "fitness", action: "save_meal_logs", surface: "fitness_log",
                workflow: "log_food"
            )
        case .logPlannedMeal:
            UsageEventDescriptor(
                module: "fitness", action: "log_planned_meal", surface: "fitness_log",
                workflow: "log_food"
            )
        case .logMealTemplate:
            UsageEventDescriptor(
                module: "fitness", action: "log_meal_template", surface: "fitness_food_editor",
                workflow: "log_food"
            )
        case .pullStrava:
            UsageEventDescriptor(
                module: "fitness", action: "pull_strava", surface: "fitness_training",
                workflow: "pull_strava"
            )
        case .bookSwimming(let surface):
            UsageEventDescriptor(
                module: "facilities", action: "book_swimming", surface: surface.rawValue,
                workflow: "book_swimming"
            )
        }
    }
}

enum UsageFailureCategory: String, Sendable {
    case validation
    case network
    case authorization
    case conflict
    case provider
    case server
    case unknown
}

struct UsageWorkflowRun: Sendable {
    fileprivate let id: UUID
    fileprivate let startedAt: Date
    fileprivate let descriptor: UsageEventDescriptor
}

private struct UsageEventDescriptor: Sendable {
    let module: String
    let action: String
    let surface: String
    var workflow: String?
}

private struct UsagePreferenceResponse: Decodable {
    let enabled: Bool
}

private struct UsageInteractionBatch: Encodable {
    let events: [UsageInteractionEvent]
}

private struct UsageInteractionEvent: Encodable, Sendable {
    let id: UUID
    let eventKind: String
    let module: String
    let action: String
    let outcome: String
    let surface: String
    let workflow: String?
    let workflowRunId: UUID?
    let durationBucket: String
    let interactionCount: Int?
    let connectivity: String
    let failureClass: String?
    let occurredAt: String
}

/// Opt-in, first-party product telemetry. Callers can select only reviewed
/// semantic IDs; no labels, typed values, record IDs or family content enter it.
actor UsageMonitor {
    static let shared = UsageMonitor()

    private let apiClient: APIClient
    private var consentIdentity: String?
    private var enabled: Bool?

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    nonisolated static func screen(_ tab: AppTab) {
        let descriptor = UsageEventDescriptor(
            module: tab.rawValue,
            action: "view_\(tab.rawValue)",
            surface: tab.rawValue
        )
        Task { await shared.submit(event(for: descriptor, kind: "screen_view", outcome: "viewed")) }
    }

    nonisolated static func control(_ control: UsageControl) {
        Task {
            await shared.submit(
                event(for: control.descriptor, kind: "control", outcome: "tapped")
            )
        }
    }

    nonisolated static func start(_ workflow: UsageWorkflow) -> UsageWorkflowRun {
        let run = UsageWorkflowRun(
            id: UUID(),
            startedAt: Date(),
            descriptor: workflow.descriptor
        )
        Task {
            await shared.submit(
                event(
                    for: run.descriptor,
                    kind: "workflow",
                    outcome: "started",
                    workflowRunId: run.id
                )
            )
        }
        return run
    }

    nonisolated static func complete(
        _ run: UsageWorkflowRun,
        interactions: Int? = nil,
        queued: Bool = false
    ) {
        finish(run, outcome: "completed", interactions: interactions, connectivity: queued ? "queued" : "online")
    }

    nonisolated static func fail(
        _ run: UsageWorkflowRun,
        error: Error,
        interactions: Int? = nil
    ) {
        finish(
            run,
            outcome: "failed",
            interactions: interactions,
            connectivity: failureClass(for: error) == "network" ? "offline" : "online",
            failureClass: failureClass(for: error)
        )
    }

    nonisolated static func fail(
        _ run: UsageWorkflowRun,
        category: UsageFailureCategory,
        interactions: Int? = nil
    ) {
        finish(
            run,
            outcome: "failed",
            interactions: interactions,
            connectivity: category == .network ? "offline" : "unknown",
            failureClass: category.rawValue
        )
    }

    nonisolated static func cancel(_ run: UsageWorkflowRun, interactions: Int? = nil) {
        finish(
            run,
            outcome: "cancelled",
            interactions: interactions,
            connectivity: "unknown",
            failureClass: "cancelled"
        )
    }

    func updateConsent(_ isEnabled: Bool) {
        consentIdentity = apiClient.currentSessionSnapshot()?.identity
        enabled = isEnabled
    }

    private func submit(_ event: UsageInteractionEvent) async {
        guard await isEnabledForCurrentAccount() else { return }
        do {
            // Keep monitoring out of the durable family-action queue. Missing
            // telemetry is preferable to occupying capacity needed by a real
            // offline booking, task or care record.
            _ = try await apiClient.postHTTPResponse(
                "/usage-history/events",
                body: UsageInteractionBatch(events: [event])
            )
        } catch {
            // Monitoring is deliberately best-effort and never interrupts the
            // family action it describes. The server remains the consent gate.
        }
    }

    private func isEnabledForCurrentAccount() async -> Bool {
        guard let session = apiClient.currentSessionSnapshot() else {
            consentIdentity = nil
            enabled = nil
            return false
        }
        if consentIdentity != session.identity {
            consentIdentity = session.identity
            enabled = nil
        }
        if let enabled { return enabled }
        do {
            let preference: UsagePreferenceResponse = try await apiClient.get(
                "/usage-history/preferences",
                cachePolicy: .networkOnly
            )
            guard apiClient.currentSessionSnapshot()?.identity == session.identity else {
                return false
            }
            enabled = preference.enabled
            return preference.enabled
        } catch {
            return false
        }
    }

    nonisolated private static func finish(
        _ run: UsageWorkflowRun,
        outcome: String,
        interactions: Int?,
        connectivity: String,
        failureClass: String? = nil
    ) {
        Task {
            await shared.submit(
                event(
                    for: run.descriptor,
                    kind: "workflow",
                    outcome: outcome,
                    workflowRunId: run.id,
                    startedAt: run.startedAt,
                    interactions: interactions,
                    connectivity: connectivity,
                    failureClass: failureClass
                )
            )
        }
    }

    nonisolated private static func event(
        for descriptor: UsageEventDescriptor,
        kind: String,
        outcome: String,
        workflowRunId: UUID? = nil,
        startedAt: Date? = nil,
        interactions: Int? = nil,
        connectivity: String = "unknown",
        failureClass: String? = nil
    ) -> UsageInteractionEvent {
        let now = Date()
        return UsageInteractionEvent(
            id: UUID(),
            eventKind: kind,
            module: descriptor.module,
            action: descriptor.action,
            outcome: outcome,
            surface: descriptor.surface,
            workflow: descriptor.workflow,
            workflowRunId: workflowRunId,
            durationBucket: durationBucket(from: startedAt, to: now),
            interactionCount: interactions.map { min(max($0, 0), 100) },
            connectivity: connectivity,
            failureClass: failureClass,
            occurredAt: ISODateParser.stringNoFractional(from: now)
        )
    }

    nonisolated private static func durationBucket(from start: Date?, to end: Date) -> String {
        guard let start else { return "unknown" }
        let duration = max(end.timeIntervalSince(start), 0)
        if duration < 10 { return "under_10s" }
        if duration < 60 { return "under_1m" }
        if duration < 300 { return "under_5m" }
        return "over_5m"
    }

    nonisolated private static func failureClass(for error: Error) -> String {
        guard let apiError = error as? APIError else { return "unknown" }
        switch apiError {
        case .unauthorized, .forbidden, .tokenRefreshFailed:
            return "authorization"
        case .conflict:
            return "conflict"
        case .networkError, .offlineQueued, .offlineQueueFull:
            return "network"
        case .serverError:
            return "server"
        case .invalidURL, .notFound, .decodingError:
            return "unknown"
        }
    }
}
