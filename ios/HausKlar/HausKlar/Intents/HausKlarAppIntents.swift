import AppIntents
import Foundation
import WidgetKit

// MARK: - Request/response payloads

/// Minimal body for POST /meals/shopping. The server fills in the rest.
private struct IntentShoppingItemBody: Encodable {
    let name: String
}

/// A trimmed shopping-item response — we only need to confirm the name back.
private struct IntentShoppingItemResponse: Decodable {
    let id: String
    let name: String
}

/// Minimal body for POST /tasks/. The server defaults the id, category and priority.
private struct IntentTaskBody: Encodable {
    let title: String
}

private struct IntentTaskResponse: Decodable {
    let id: String
    let title: String
}

// MARK: - Add to shopping list

/// Adds an item to the family shopping list by voice — hands-full friendly.
struct AddShoppingItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to shopping list"
    static let description = IntentDescription("Adds an item to the HausKlar family shopping list.")

    /// Requires the device to be unlocked — this touches family data.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    /// Runs without launching the app so it works hands-free.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Item", requestValueDialog: "What should I add to the shopping list?")
    var item: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to the shopping list")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .result(dialog: "I didn't catch what to add. Please try again.")
        }
        do {
            let created: IntentShoppingItemResponse = try await IntentAPIClient.post(
                "/meals/shopping",
                body: IntentShoppingItemBody(name: name)
            )
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "Added \(created.name) to your shopping list.")
        } catch let error as IntentAPIError {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }
    }
}

// MARK: - Add a task

/// Creates a family task by voice.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a task"
    static let description = IntentDescription("Creates a task in HausKlar.")

    /// Requires the device to be unlocked — this touches family data.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var taskTitle: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add task \(\.$taskTitle)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return .result(dialog: "I didn't catch the task. Please try again.")
        }
        do {
            let created: IntentTaskResponse = try await IntentAPIClient.post(
                "/tasks/",
                body: IntentTaskBody(title: title)
            )
            WidgetCenter.shared.reloadAllTimelines()
            return .result(dialog: "Added \(created.title) to your tasks.")
        } catch let error as IntentAPIError {
            return .result(dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }
    }
}

// MARK: - Ask Bismarck

/// Asks the family assistant a question and speaks the answer back.
struct AskBismarckIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Bismarck"
    static let description = IntentDescription("Asks the HausKlar family assistant a question.")

    /// Requires the device to be unlocked — Bismarck can speak child health facts,
    /// so it must never answer from a locked device.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Question", requestValueDialog: "What would you like to ask Bismarck?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Bismarck \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .result(value: "", dialog: "I didn't catch your question. Please try again.")
        }
        do {
            let response: AssistantMessageResponseDTO = try await IntentAPIClient.post(
                "/assistant/message",
                body: AssistantMessageRequestDTO(
                    message: text,
                    history: [],
                    clientNow: ISODateParser.string(from: Date()),
                    timezone: TimeZone.current.identifier
                )
            )
            let answer = response.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = answer.isEmpty ? "Bismarck didn't have an answer for that." : answer
            return .result(value: answer, dialog: IntentDialog(stringLiteral: spoken))
        } catch let error as IntentAPIError {
            return .result(value: "", dialog: IntentDialog(stringLiteral: error.localizedDescription))
        }
    }
}

// MARK: - Ambient family jobs

private enum AmbientIntentSupport {
    @MainActor
    static func glance() async throws -> GlanceDTO {
        do {
            let glance: GlanceDTO = try await IntentAPIClient.get(
                "/briefing/glance",
                queryItems: [
                    URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
                ]
            )
            GlanceStore.save(glance)
            return glance
        } catch {
            if let cached = GlanceStore.load()?.glance { return cached }
            throw error
        }
    }

    static func open(_ url: URL) throws {
        try AmbientIntentRouteStore.save(url)
    }

    static func dialog(for error: Error) -> IntentDialog {
        if let error = error as? IntentAPIError {
            return IntentDialog(stringLiteral: error.localizedDescription)
        }
        return "HausKlar couldn't open that just now."
    }
}

/// Opens the exact next event. It never creates or edits calendar data.
struct OpenNextEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Open next event"
    static let description = IntentDescription("Opens the next family calendar event in HausKlar.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let glance = try await AmbientIntentSupport.glance()
            guard let event = glance.nextEvent() else {
                try AmbientIntentSupport.open(AmbientDeepLink.today)
                return .result(dialog: "There are no more events today.")
            }
            try AmbientIntentSupport.open(AmbientDeepLink.calendarEvent(id: event.id))
            return .result(dialog: IntentDialog(stringLiteral: "Opening \(event.title)."))
        } catch {
            return .result(dialog: AmbientIntentSupport.dialog(for: error))
        }
    }
}

/// Opens the longest-running active nap so ending it remains a deliberate tap.
struct OpenActiveNapIntent: AppIntent {
    static let title: LocalizedStringResource = "Open active nap"
    static let description = IntentDescription("Opens the active nap in HausKlar without ending it.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let glance = try await AmbientIntentSupport.glance()
            guard let nap = glance.longestActiveNap else {
                try AmbientIntentSupport.open(AmbientDeepLink.naps)
                return .result(dialog: "There isn't an active nap.")
            }
            try AmbientIntentSupport.open(
                AmbientDeepLink.activeNap(napId: nap.id, childId: nap.childId)
            )
            return .result(dialog: IntentDialog(stringLiteral: "Opening \(nap.childName)'s nap."))
        } catch {
            return .result(dialog: AmbientIntentSupport.dialog(for: error))
        }
    }
}

/// Opens today's dog-care surface at the next useful job. It does not log care.
struct OpenDogCareIntent: AppIntent {
    static let title: LocalizedStringResource = "Open dog care"
    static let description = IntentDescription("Opens today's dog care in HausKlar.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let glance = try await AmbientIntentSupport.glance()
            let job = glance.dogCare?.nextJob
            try AmbientIntentSupport.open(
                AmbientDeepLink.dogCare(
                    action: job?.action,
                    activityId: job?.activityId
                )
            )
            return .result(dialog: IntentDialog(stringLiteral: job?.detail ?? "Opening dog care."))
        } catch {
            return .result(dialog: AmbientIntentSupport.dialog(for: error))
        }
    }
}

/// Places dictated or typed text into Universal Capture for review.
struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture text"
    static let description = IntentDescription("Opens editable text in HausKlar Capture for review.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true

    @Parameter(title: "Text", requestValueDialog: "What should I capture?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Capture text in HausKlar")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return .result(dialog: "I didn't catch anything to capture.")
        }
        do {
            try AmbientIntentSupport.open(AmbientDeepLink.capture(text: clean))
            return .result(dialog: "Opening Capture for review.")
        } catch {
            return .result(dialog: AmbientIntentSupport.dialog(for: error))
        }
    }
}

/// Opens the currently relevant chart; awarding a star still requires a tap.
struct OpenStarChartIntent: AppIntent {
    static let title: LocalizedStringResource = "Open star chart"
    static let description = IntentDescription("Opens the current star chart without awarding a star.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let glance = try await AmbientIntentSupport.glance()
            guard let chart = glance.starChart else {
                try AmbientIntentSupport.open(AmbientDeepLink.starCharts)
                return .result(dialog: "There isn't an active star chart.")
            }
            try AmbientIntentSupport.open(
                AmbientDeepLink.starChart(childId: chart.childId, chartId: chart.chartId)
            )
            return .result(dialog: IntentDialog(stringLiteral: "Opening \(chart.childName)'s chart."))
        } catch {
            return .result(dialog: AmbientIntentSupport.dialog(for: error))
        }
    }
}

/// Medicine is review-only from ambient surfaces. It never records a dose.
struct ReviewMedicineIntent: AppIntent {
    static let title: LocalizedStringResource = "Review medicine timing"
    static let description = IntentDescription("Opens medicine timing for review without recording a dose.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let glance = try await AmbientIntentSupport.glance()
            guard let medicine = glance.medicineToReview() else {
                try AmbientIntentSupport.open(
                    AmbientDeepLink.medicineReview(childId: nil, medicineTypeId: nil)
                )
                return .result(dialog: "No medicine timing is being tracked.")
            }
            try AmbientIntentSupport.open(
                AmbientDeepLink.medicineReview(
                    childId: medicine.childId,
                    medicineTypeId: medicine.medicineTypeId
                )
            )
            return .result(dialog: "Opening medicine timing for review.")
        } catch {
            return .result(dialog: AmbientIntentSupport.dialog(for: error))
        }
    }
}
