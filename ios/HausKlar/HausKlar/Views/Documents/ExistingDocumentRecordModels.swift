import SwiftData
import SwiftUI

enum ExistingDocumentRecordKind: String, CaseIterable, Identifiable {
    case event = "Events"
    case task = "Tasks"

    var id: String { rawValue }
}

struct ExistingDocumentRecordChoice: Identifiable, Equatable {
    let kind: ExistingDocumentRecordKind
    let recordId: String
    let title: String
    let subtitle: String
    var sourceDocumentId: String?

    var id: String { "\(kind.rawValue)-\(recordId)" }
}

typealias ExistingDocumentEventLoader = @Sendable () async throws -> [CalendarEventDTO]
typealias ExistingDocumentTaskLoader = @Sendable () async throws -> [TaskDTO]
typealias ExistingDocumentRecordLinker = (String, String) async throws -> Void

/// Loads linkable records and attaches a document with a source-only update,
/// avoiding stale form data overwriting concurrent calendar or task edits.
@MainActor
final class ExistingDocumentRecordPickerViewModel: ObservableObject {
    @Published private(set) var choices: [ExistingDocumentRecordChoice] = []
    @Published private(set) var isLoading = false
    @Published private(set) var savingChoiceId: String?
    @Published var errorMessage: String?

    let documentId: String
    private let eventLoader: ExistingDocumentEventLoader
    private let taskLoader: ExistingDocumentTaskLoader
    private let eventLinker: ExistingDocumentRecordLinker
    private let taskLinker: ExistingDocumentRecordLinker

    init(
        documentId: String,
        referenceDate: Date = Date(),
        eventLoader: ExistingDocumentEventLoader? = nil,
        taskLoader: @escaping ExistingDocumentTaskLoader = {
            try await APIClient.shared.get(
                "/tasks/",
                queryItems: [
                    URLQueryItem(name: "limit", value: "200")
                ],
                bypassCache: true
            )
        },
        eventLinker: @escaping ExistingDocumentRecordLinker = { eventId, documentId in
            let _: CalendarEventDTO = try await APIClient.shared.put(
                "/calendar/\(eventId)",
                body: SourceDocumentLinkUpdateRequest(sourceDocumentId: documentId)
            )
        },
        taskLinker: @escaping ExistingDocumentRecordLinker = { taskId, documentId in
            let _: TaskDTO = try await APIClient.shared.put(
                "/tasks/\(taskId)",
                body: SourceDocumentLinkUpdateRequest(sourceDocumentId: documentId)
            )
        }
    ) {
        self.documentId = documentId
        self.eventLoader = eventLoader ?? Self.defaultEventLoader(referenceDate: referenceDate)
        self.taskLoader = taskLoader
        self.eventLinker = eventLinker
        self.taskLinker = taskLinker
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let loadedEvents = eventLoader()
            async let loadedTasks = taskLoader()
            let (events, tasks) = try await (loadedEvents, loadedTasks)
            choices = Self.eventChoices(events) + Self.taskChoices(tasks)
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Calendar events and tasks could not be loaded."
        }
    }

    func filteredChoices(
        kind: ExistingDocumentRecordKind,
        searchText: String
    ) -> [ExistingDocumentRecordChoice] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return choices.filter { choice in
            guard choice.kind == kind else { return false }
            return query.isEmpty
                || choice.title.localizedCaseInsensitiveContains(query)
                || choice.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    func attach(to choice: ExistingDocumentRecordChoice) async -> Bool {
        guard choice.sourceDocumentId != documentId else { return true }
        savingChoiceId = choice.id
        errorMessage = nil
        defer { savingChoiceId = nil }
        do {
            switch choice.kind {
            case .event:
                try await eventLinker(choice.recordId, documentId)
            case .task:
                try await taskLinker(choice.recordId, documentId)
            }
            if let index = choices.firstIndex(where: { $0.id == choice.id }) {
                choices[index].sourceDocumentId = documentId
            }
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The document could not be attached. Try again."
        }
        return false
    }

    private static func eventChoices(
        _ events: [CalendarEventDTO]
    ) -> [ExistingDocumentRecordChoice] {
        var seen: Set<String> = []
        return events.compactMap { event in
            let recordId = event.seriesId ?? event.id
            guard seen.insert(recordId).inserted else { return nil }
            return ExistingDocumentRecordChoice(
                kind: .event,
                recordId: recordId,
                title: event.title,
                subtitle: eventSubtitle(event),
                sourceDocumentId: event.sourceDocumentId
            )
        }
    }

    private static func taskChoices(
        _ tasks: [TaskDTO]
    ) -> [ExistingDocumentRecordChoice] {
        tasks.compactMap { task in
            guard task.createdBy != "bin-scraper" else { return nil }
            var details: [String] = []
            if task.completedAt != nil {
                details.append("Completed")
            }
            if let dueDate = task.dueDate, let date = ISODateParser.parse(dueDate) {
                details.append("Due \(date.formatted(date: .abbreviated, time: .omitted))")
            }
            if details.isEmpty { details.append("No due date") }
            return ExistingDocumentRecordChoice(
                kind: .task,
                recordId: task.id,
                title: task.title,
                subtitle: details.joined(separator: " · "),
                sourceDocumentId: task.sourceDocumentId
            )
        }
    }

    private static func eventSubtitle(_ event: CalendarEventDTO) -> String {
        guard let date = ISODateParser.parse(event.startTime) else { return event.startTime }
        return date.formatted(
            date: .abbreviated,
            time: event.allDay ? .omitted : .shortened
        )
    }

    private static func defaultEventLoader(referenceDate: Date) -> ExistingDocumentEventLoader {
        {
            let calendar = Calendar.current
            let centre = calendar.startOfDay(for: referenceDate)
            let start = calendar.date(byAdding: .day, value: -180, to: centre) ?? centre
            let end = calendar.date(byAdding: .day, value: 180, to: centre) ?? centre
            return try await APIClient.shared.get(
                "/calendar/",
                queryItems: [
                    URLQueryItem(name: "start", value: ISODateParser.dateOnly(from: start)),
                    URLQueryItem(name: "end", value: ISODateParser.dateOnly(from: end)),
                    URLQueryItem(name: "limit", value: "200"),
                ],
                bypassCache: true
            )
        }
    }
}
