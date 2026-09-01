import SwiftUI

struct FacilitySwimmingBookingSelection: Identifiable, Equatable {
    let date: String
    let start: String
    let end: String
    let sourceSurface: UsageSurface

    var id: String { "\(date):\(start):\(end)" }

    init(
        date: String,
        window: FacilityTimeWindowDTO,
        sourceSurface: UsageSurface = .todayFacilities
    ) {
        self.date = date
        start = window.start
        end = window.end
        self.sourceSurface = sourceSurface
    }

    init?(event: CalendarEventDTO) {
        guard event.eventType == "facility_family_swimming",
              let startDate = ISODateParser.parse(event.startTime),
              let rawEnd = event.endTime,
              let endDate = ISODateParser.parse(rawEnd)
        else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "yyyy-MM-dd"
        date = formatter.string(from: startDate)
        formatter.dateFormat = "HH:mm"
        start = formatter.string(from: startDate)
        end = formatter.string(from: endDate)
        sourceSurface = .calendarEvent
    }
}

private struct FacilitySwimmingBookingRequest: Encodable {
    let id: String
    let date: String
    let start: String
    let end: String
    let clientId: String
    let clientTimestamp: String
}

private struct FacilitySwimmingBookingResponse: Decodable {
    let status: String
    let eventId: String
}

@MainActor
final class FacilitySwimmingBookingViewModel: ObservableObject {
    @Published var startTime: Date
    @Published var endTime: Date
    @Published var isSaving = false
    @Published var errorMessage: String?

    let selection: FacilitySwimmingBookingSelection
    let windowStart: Date
    let windowEnd: Date

    private let apiClient: APIClient
    private var pendingOperation: (id: String, fingerprint: String, timestamp: String)?
    private var usageRun: UsageWorkflowRun?
    private var usageInteractions = 1

    private static let londonTimeZone = TimeZone(identifier: "Europe/London")!

    init(
        selection: FacilitySwimmingBookingSelection,
        apiClient: APIClient = .shared
    ) {
        self.selection = selection
        self.apiClient = apiClient
        let start = Self.parse(date: selection.date, time: selection.start) ?? Date()
        let end = Self.parse(date: selection.date, time: selection.end)
            ?? start.addingTimeInterval(60 * 60)
        windowStart = start
        windowEnd = end
        startTime = start
        endTime = min(start.addingTimeInterval(60 * 60), end)
        usageRun = UsageMonitor.start(.bookSwimming(selection.sourceSurface))
    }

    var latestStart: Date {
        max(windowStart, windowEnd.addingTimeInterval(-60))
    }

    var earliestEnd: Date {
        min(windowEnd, startTime.addingTimeInterval(60))
    }

    var canSave: Bool {
        !isSaving
            && startTime >= windowStart
            && endTime <= windowEnd
            && endTime > startTime
    }

    func keepEndAfterStart() {
        usageInteractions = min(usageInteractions + 1, 100)
        if endTime <= startTime {
            endTime = min(startTime.addingTimeInterval(60 * 60), windowEnd)
        }
    }

    func noteEndTimeChanged() {
        usageInteractions = min(usageInteractions + 1, 100)
    }

    func save() async -> String? {
        guard canSave else {
            errorMessage = "Choose a start and end within \(selection.start)–\(selection.end)."
            return nil
        }
        if usageRun == nil {
            usageRun = UsageMonitor.start(.bookSwimming(selection.sourceSurface))
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let start = Self.timeString(startTime)
        let end = Self.timeString(endTime)
        let fingerprint = "\(selection.date)|\(start)|\(end)"
        let operation: (id: String, fingerprint: String, timestamp: String)
        if let pendingOperation, pendingOperation.fingerprint == fingerprint {
            operation = pendingOperation
        } else {
            operation = (
                UUID().uuidString.lowercased(),
                fingerprint,
                ISODateParser.stringNoFractional(from: Date())
            )
            pendingOperation = operation
        }

        do {
            let response: FacilitySwimmingBookingResponse = try await apiClient.post(
                "/facilities/swimming-bookings",
                body: FacilitySwimmingBookingRequest(
                    id: operation.id,
                    date: selection.date,
                    start: start,
                    end: end,
                    clientId: try apiClient.clientId,
                    clientTimestamp: operation.timestamp
                )
            )
            guard response.status == "booked", !response.eventId.isEmpty else {
                errorMessage = "Swimming could not be added to the calendar."
                finishUsageAsFailure(APIError.serverError(statusCode: 502, message: nil))
                HapticManager.error()
                return nil
            }
            pendingOperation = nil
            finishUsageAsCompleted()
            NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            HapticManager.success()
            return "Swimming added to the family calendar."
        } catch APIError.offlineQueued {
            pendingOperation = nil
            finishUsageAsCompleted(queued: true)
            NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            HapticManager.success()
            return "Swimming saved offline. It will be added to the family calendar when HausKlar reconnects."
        } catch let error as APIError {
            errorMessage = error.errorDescription
            finishUsageAsFailure(error)
        } catch let error as ClientIdentityError {
            errorMessage = error.errorDescription
            finishUsageAsFailure(error)
        } catch {
            errorMessage = "Swimming could not be added to the calendar. Try again."
            finishUsageAsFailure(error)
        }
        HapticManager.error()
        return nil
    }

    func cancelUsageIfNeeded() {
        guard let usageRun, !isSaving else { return }
        UsageMonitor.cancel(usageRun, interactions: usageInteractions)
        self.usageRun = nil
    }

    private func finishUsageAsCompleted(queued: Bool = false) {
        guard let usageRun else { return }
        UsageMonitor.complete(
            usageRun,
            interactions: usageInteractions,
            queued: queued
        )
        self.usageRun = nil
    }

    private func finishUsageAsFailure(_ error: Error) {
        guard let usageRun else { return }
        UsageMonitor.fail(usageRun, error: error, interactions: usageInteractions)
        self.usageRun = nil
    }

    private static func parse(date: String, time: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = londonTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(time)")
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = londonTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct FacilitySwimmingBookingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: FacilitySwimmingBookingViewModel

    let onBooked: (String) -> Void

    init(
        selection: FacilitySwimmingBookingSelection,
        onBooked: @escaping (String) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: FacilitySwimmingBookingViewModel(selection: selection)
        )
        self.onBooked = onBooked
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Booked slot") {
                    LabeledContent("Date") {
                        Text(
                            viewModel.windowStart,
                            format: .dateTime.weekday(.wide).day().month(.wide)
                        )
                    }
                    LabeledContent("Available", value: "\(viewModel.selection.start)–\(viewModel.selection.end)")
                    DatePicker(
                        "Starts",
                        selection: $viewModel.startTime,
                        in: viewModel.windowStart...viewModel.latestStart,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: viewModel.endTime) { _, _ in
                        viewModel.noteEndTimeChanged()
                    }
                    .onChange(of: viewModel.startTime) { _, _ in
                        viewModel.keepEndAfterStart()
                    }
                    DatePicker(
                        "Ends",
                        selection: $viewModel.endTime,
                        in: viewModel.earliestEnd...viewModel.windowEnd,
                        displayedComponents: .hourAndMinute
                    )
                    Text("Use the exact slot you booked. Everyone will see it in the family calendar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("swimmingBookingError")
                    }
                }
            }
            .environment(\.timeZone, TimeZone(identifier: "Europe/London")!)
            .navigationTitle("Add booked swimming")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelUsageIfNeeded()
                        dismiss()
                    }
                        .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if let notice = await viewModel.save() {
                                onBooked(notice)
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView()
                        } else {
                            Text("Add to calendar")
                        }
                    }
                    .disabled(!viewModel.canSave)
                    .accessibilityIdentifier("addSwimmingBookingButton")
                }
            }
        }
        .onDisappear { viewModel.cancelUsageIfNeeded() }
        .interactiveDismissDisabled(viewModel.isSaving)
        .presentationDetents([.medium])
    }
}

struct FacilityWeightsBookingSelection: Identifiable, Equatable {
    let date: String
    let start: String
    let end: String

    var id: String { "\(date):\(start):\(end)" }

    init(date: String, window: FacilityTimeWindowDTO) {
        self.date = date
        start = window.start
        end = window.end
    }

    init?(event: CalendarEventDTO) {
        guard event.eventType == "facility_weights_room",
              let startDate = ISODateParser.parse(event.startTime),
              let rawEnd = event.endTime,
              let endDate = ISODateParser.parse(rawEnd)
        else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "yyyy-MM-dd"
        date = formatter.string(from: startDate)
        formatter.dateFormat = "HH:mm"
        start = formatter.string(from: startDate)
        end = formatter.string(from: endDate)
    }
}

private struct FacilityWeightsBookingRequest: Encodable {
    let id: String
    let date: String
    let start: String
    let end: String
    let clientId: String
    let clientTimestamp: String
}

private struct FacilityWeightsBookingResponse: Decodable {
    let status: String
    let plannedSessionId: String
}

@MainActor
final class FacilityWeightsBookingViewModel: ObservableObject {
    @Published var startTime: Date
    @Published var endTime: Date
    @Published var isSaving = false
    @Published var errorMessage: String?

    let selection: FacilityWeightsBookingSelection
    let windowStart: Date
    let windowEnd: Date

    private let apiClient: APIClient
    private var pendingOperation: (id: String, fingerprint: String, timestamp: String)?

    private static let londonTimeZone = TimeZone(identifier: "Europe/London")!

    init(
        selection: FacilityWeightsBookingSelection,
        apiClient: APIClient = .shared
    ) {
        self.selection = selection
        self.apiClient = apiClient
        let start = Self.parse(date: selection.date, time: selection.start) ?? Date()
        let end = Self.parse(date: selection.date, time: selection.end)
            ?? start.addingTimeInterval(60 * 60)
        windowStart = start
        windowEnd = end
        startTime = start
        endTime = min(start.addingTimeInterval(60 * 60), end)
    }

    var latestStart: Date {
        max(windowStart, windowEnd.addingTimeInterval(-60))
    }

    var earliestEnd: Date {
        min(windowEnd, startTime.addingTimeInterval(60))
    }

    var canSave: Bool {
        !isSaving
            && startTime >= windowStart
            && endTime <= windowEnd
            && endTime > startTime
    }

    func keepEndAfterStart() {
        if endTime <= startTime {
            endTime = min(startTime.addingTimeInterval(60 * 60), windowEnd)
        }
    }

    func save() async -> String? {
        guard canSave else {
            errorMessage = "Choose a start and end within \(selection.start)–\(selection.end)."
            return nil
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let start = Self.timeString(startTime)
        let end = Self.timeString(endTime)
        let fingerprint = "\(selection.date)|\(start)|\(end)"
        let operation: (id: String, fingerprint: String, timestamp: String)
        if let pendingOperation, pendingOperation.fingerprint == fingerprint {
            operation = pendingOperation
        } else {
            operation = (
                UUID().uuidString.lowercased(),
                fingerprint,
                ISODateParser.stringNoFractional(from: Date())
            )
            pendingOperation = operation
        }

        do {
            let response: FacilityWeightsBookingResponse = try await apiClient.post(
                "/facilities/weights-bookings",
                body: FacilityWeightsBookingRequest(
                    id: operation.id,
                    date: selection.date,
                    start: start,
                    end: end,
                    clientId: try apiClient.clientId,
                    clientTimestamp: operation.timestamp
                ),
                operationID: operation.id
            )
            guard response.status == "planned", !response.plannedSessionId.isEmpty else {
                errorMessage = "Strength could not be planned."
                HapticManager.error()
                return nil
            }
            pendingOperation = nil
            NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            HapticManager.success()
            return "Strength added to Calendar and Today."
        } catch APIError.offlineQueued {
            pendingOperation = nil
            NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            HapticManager.success()
            return "Strength saved offline. It will appear when HausKlar reconnects."
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch let error as ClientIdentityError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Strength could not be planned. Try again."
        }
        HapticManager.error()
        return nil
    }

    private static func parse(date: String, time: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = londonTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(date) \(time)")
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = londonTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

struct FacilityWeightsBookingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: FacilityWeightsBookingViewModel

    let onBooked: (String) -> Void

    init(
        selection: FacilityWeightsBookingSelection,
        onBooked: @escaping (String) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: FacilityWeightsBookingViewModel(selection: selection)
        )
        self.onBooked = onBooked
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Date") {
                        Text(
                            viewModel.windowStart,
                            format: .dateTime.weekday(.wide).day().month(.wide)
                        )
                    }
                    LabeledContent(
                        "Available",
                        value: "\(viewModel.selection.start)–\(viewModel.selection.end)"
                    )
                    DatePicker(
                        "Starts",
                        selection: $viewModel.startTime,
                        in: viewModel.windowStart...viewModel.latestStart,
                        displayedComponents: .hourAndMinute
                    )
                    .onChange(of: viewModel.startTime) { _, _ in
                        viewModel.keepEndAfterStart()
                    }
                    DatePicker(
                        "Ends",
                        selection: $viewModel.endTime,
                        in: viewModel.earliestEnd...viewModel.windowEnd,
                        displayedComponents: .hourAndMinute
                    )
                    Text("It will appear in Calendar and on Today.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("weightsBookingError")
                    }
                }
            }
            .environment(\.timeZone, TimeZone(identifier: "Europe/London")!)
            .navigationTitle("Plan strength")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if let notice = await viewModel.save() {
                                onBooked(notice)
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView()
                        } else {
                            Text("Add strength")
                        }
                    }
                    .disabled(!viewModel.canSave)
                    .accessibilityIdentifier("addWeightsBookingButton")
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .presentationDetents([.medium])
    }
}
