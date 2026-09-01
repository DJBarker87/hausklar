import Foundation
import SwiftData
import SwiftUI
import os

// DTOs and supporting types are now in DTOs/CalendarDTOs.swift

struct FitnessCalendarPreferenceDTO: Codable, Equatable {
    let showPlanned: Bool
    let showCompleted: Bool
}

struct FitnessCalendarProjection {
    let events: [CalendarEventDTO]
    let intentsByEventId: [String: FitnessDeepLinkIntent]

    static let empty = FitnessCalendarProjection(events: [], intentsByEventId: [:])
}

enum PlannerDayItemKind {
    case event(CalendarEventDTO)
    case coordination(handoffs: [HandoffOccurrenceDTO], toast: [CalendarEventDTO])
    case routine(ActiveRoutineDTO)
    case task(TaskDTO)
    case prep(PrepPackSuggestionDTO)
}

struct PlannerDayItem: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let timeLabel: String
    let sortDate: Date?
    let sortRank: Int
    let kind: PlannerDayItemKind
}

private struct CalendarMutationErrorResponse: Decodable {
    let detail: String?
}

private enum DurableCalendarError: LocalizedError {
    case duplicateLocalRecord
    case invalidLocalRecord

    var errorDescription: String? {
        switch self {
        case .duplicateLocalRecord:
            "More than one local event has the same identifier."
        case .invalidLocalRecord:
            "The event could not be represented safely on this device."
        }
    }
}

// MARK: - ViewModel

/// ViewModel for the calendar feature. Manages event loading, creation, and deletion.
@MainActor
final class CalendarViewModel: ObservableObject {

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "CalendarViewModel"
    )

    // MARK: - Family Members (fetched from API)

    @Published var familyMembers: [FamilyMemberDTO] = []
    @Published private(set) var familyMembersLoadFailed = false
    @Published private(set) var hasLoadedFamilyMembers = false

    var familyMembersAvailable: Bool {
        hasLoadedFamilyMembers || !familyMembers.isEmpty
    }

    var eventPeopleEditingUnavailable: Bool {
        editingEvent != nil && !familyMembersAvailable
    }

    var adults: [FamilyMemberDTO] {
        familyMembers.filter { $0.memberType == "user" }
    }

    var childMembers: [FamilyMemberDTO] {
        familyMembers.filter { $0.memberType == "child" }
    }

    var childIds: Set<String> {
        Set(childMembers.map { $0.id })
    }

    private static let adultColors: [Color] = [.blue, .pink, .purple, .teal, .indigo]
    private static let childColors: [Color] = [.green, .orange, .mint, .cyan, .yellow]

    func colorForMember(_ id: String) -> Color {
        if let idx = adults.firstIndex(where: { $0.id == id }) {
            return Self.adultColors[idx % Self.adultColors.count]
        }
        if let idx = childMembers.firstIndex(where: { $0.id == id }) {
            return Self.childColors[idx % Self.childColors.count]
        }
        return .accentColor
    }

    func nameForMember(_ id: String) -> String? {
        familyMembers.first(where: { $0.id == id })?.name
    }

    func participantIDs(for event: CalendarEventDTO) -> Set<String> {
        var ids = Set(event.familyMemberIds ?? [])
        if let assignedTo = event.assignedTo { ids.insert(assignedTo) }
        return ids
    }

    func primaryParticipantID(for event: CalendarEventDTO) -> String? {
        familyMembers.first(where: { participantIDs(for: event).contains($0.id) })?.id
    }

    func participantLabel(for event: CalendarEventDTO) -> String {
        let ids = participantIDs(for: event)
        guard !ids.isEmpty else { return "Everyone" }
        let names = familyMembers.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? "Family members" : names.joined(separator: " & ")
    }

    func affectedLabel(for event: CalendarEventDTO) -> String? {
        let ids = Set(event.affectedMemberIds ?? [])
        let names = familyMembers.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: " & ")
    }

    func colorForEvent(_ event: CalendarEventDTO) -> Color {
        guard let id = primaryParticipantID(for: event) else { return .accentColor }
        return colorForMember(id)
    }

    var columns: [ColumnDef] {
        var cols: [ColumnDef] = [ColumnDef(kind: .viewAll, label: "Family", color: .accentColor)]
        for (i, adult) in adults.enumerated() {
            cols.append(ColumnDef(kind: .person(id: adult.id), label: adult.name, color: Self.adultColors[i % Self.adultColors.count]))
        }
        if !childMembers.isEmpty {
            cols.append(ColumnDef(kind: .kids, label: "Kids", color: .green))
        }
        cols.append(ColumnDef(kind: .everyone, label: "Shared", color: .purple))
        return cols
    }

    // MARK: - State

    @Published var events: [CalendarEventDTO] = []
    @Published var selectedDate: Date = Date()
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var loadedEventInterval: DateInterval?
    @Published var showingAddEvent = false
    @Published var editingEvent: CalendarEventDTO?
    @Published private(set) var editingRecurrenceScope: CalendarRecurrenceMutationScope?
    @Published var selectedColumnId: String = "__all__"
    @Published var viewMode: CalendarViewMode = .day
    @Published var kidsExpanded = false
    @Published var selectedChildFilterId: String?
    @Published var activeRoutines: [ActiveRoutineDTO] = []
    @Published var handoffs: [HandoffOccurrenceDTO] = []
    @Published private(set) var handoffSchedule: [HandoffScheduleItemDTO] = []
    @Published private(set) var handoffBusy = false
    @Published var handoffError: String?
    @Published private(set) var schoolClubs: [SchoolClubDTO] = []
    @Published private(set) var schoolClubBusy = false
    @Published var schoolClubError: String?
    @Published private(set) var toastImportStatus: [ToastImportStatusDTO] = []
    @Published private(set) var toastImportPreview: ToastImportPreviewDTO?
    @Published private(set) var toastImportBusy = false
    @Published var toastImportError: String?
    @Published private(set) var toastImportNotice: String?
    @Published var plannerTasks: [TaskDTO] = []
    @Published var plannerPrepSuggestions: [PrepPackSuggestionDTO] = []
    @Published var prepBusyId: String?
    @Published var termStatuses: [String: Bool] = [:]
    @Published var termAllSame: Bool = true
    @Published var yearlyTermDates: [TermDateDTO] = []
    @Published var yearlyHolidayDates: [HolidayDateDTO] = []
    @Published var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @Published private(set) var financeProjectionPreference: FinanceProjectionPreferenceDTO?
    @Published private(set) var isUpdatingFinanceProjectionPreference = false
    @Published private(set) var showFitnessPlans = true
    @Published private(set) var showCompletedFitness = false
    @Published private(set) var facilityCalendarPreference: FacilityCalendarPreferenceDTO?
    @Published private(set) var isUpdatingFacilityCalendarPreference = false
    @Published private(set) var facilityImportPreview: FacilityImportPreviewDTO?
    @Published private(set) var facilityImportBusy = false
    @Published private(set) var facilityImportError: String?
    @Published private(set) var facilityImportNotice: String?

    var selectedColumnDef: ColumnDef? {
        columns.first(where: { $0.id == selectedColumnId })
    }

    var isViewAllSelected: Bool { selectedColumnId == "__all__" }
    var isKidsSelected: Bool { selectedColumnId == "__kids__" }

    // MARK: - Form Fields

    @Published var formTitle = ""
    @Published var formStartTime = Date()
    @Published var formEndTime = Date().addingTimeInterval(15 * 60)
    @Published var formAllDay = true
    @Published var formDurationOption: CalendarEventDurationOption = .fifteenMinutes
    @Published var formAllDayIsMultiDay = false
    @Published var formAllDayEndDate = Date()
    @Published var formLocation = ""
    @Published var formDescription = ""
    @Published var formWholeFamily = true
    @Published var formParticipantIDs: Set<String> = []
    @Published var formAffectedMemberIDs: Set<String> = []
    @Published var formRecurrence = "never"
    @Published var formSourceDocumentId: String?
    @Published var formSourceDocument: SourceDocumentDTO?
    @Published var formAttachments: [CalendarEventAttachmentInput] = []
    @Published var formAttachmentDocuments: [String: SourceDocumentDTO] = [:]

    private var formTimingWasEdited = false
    private var formRecurrenceWasEdited = false
    private var formPeopleWereEdited = false
    private struct FormTiming: Equatable {
        let startTime: String
        let endTime: String?
        let allDay: Bool
    }
    private var editingInitialTiming: FormTiming?
    private var editingInitialRecurrence = "never"
    private var editingInitialWholeFamily = true
    private var editingInitialParticipantIDs: Set<String> = []
    private var editingInitialAffectedMemberIDs: Set<String> = []
    private var editingInitialTitle = ""
    private var editingInitialDescription: String?
    private var editingInitialLocation: String?
    private var editingInitialSourceDocumentId: String?
    private var editingInitialAttachments: [CalendarEventAttachmentInput] = []

    var formEveryoneSelected: Bool {
        formWholeFamily
    }

    var formOtherAdults: [FamilyMemberDTO] {
        formWholeFamily ? [] : adults.filter { !formParticipantIDs.contains($0.id) }
    }

    func setFormEveryone(_ selected: Bool) {
        guard !eventPeopleEditingUnavailable else { return }
        if editingEvent != nil { formPeopleWereEdited = true }
        formWholeFamily = selected
        if selected {
            formParticipantIDs = []
            formAffectedMemberIDs = []
        }
    }

    func setFormParticipant(_ id: String, selected: Bool) {
        guard !eventPeopleEditingUnavailable else { return }
        if editingEvent != nil { formPeopleWereEdited = true }
        if selected {
            formWholeFamily = false
            formParticipantIDs.insert(id)
            formAffectedMemberIDs.remove(id)
        } else {
            formParticipantIDs.remove(id)
        }
    }

    func setFormAffectedAdult(_ id: String, selected: Bool) {
        guard !eventPeopleEditingUnavailable else { return }
        if editingEvent != nil { formPeopleWereEdited = true }
        if selected { formAffectedMemberIDs.insert(id) }
        else { formAffectedMemberIDs.remove(id) }
    }

    func setFormAllDay(_ allDay: Bool) {
        if editingEvent != nil { formTimingWasEdited = true }
        formAllDay = allDay
        guard !allDay else { return }
        if formDurationOption == .none {
            setFormDuration(.fifteenMinutes)
        } else if let seconds = formDurationOption.seconds {
            formEndTime = formStartTime.addingTimeInterval(seconds)
        } else if formEndTime <= formStartTime {
            formEndTime = formStartTime.addingTimeInterval(15 * 60)
        }
    }

    /// Keeps a selected preset/custom duration stable when the event start moves.
    func setFormStartTime(_ newStart: Date, calendar: Calendar = .current) {
        if editingEvent != nil { formTimingWasEdited = true }
        let oldStart = formStartTime
        if formAllDay {
            let span = max(
                0,
                calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: oldStart),
                    to: calendar.startOfDay(for: formAllDayEndDate)
                ).day ?? 0
            )
            formStartTime = newStart
            formAllDayEndDate = calendar.date(
                byAdding: .day,
                value: span,
                to: newStart
            ) ?? newStart
            return
        }

        let customDuration = max(60, formEndTime.timeIntervalSince(oldStart))
        formStartTime = newStart
        if let seconds = formDurationOption.seconds {
            formEndTime = newStart.addingTimeInterval(seconds)
        } else if formDurationOption == .custom {
            formEndTime = newStart.addingTimeInterval(customDuration)
        }
    }

    func setFormDuration(_ option: CalendarEventDurationOption) {
        if editingEvent != nil { formTimingWasEdited = true }
        formDurationOption = option
        if let seconds = option.seconds {
            formEndTime = formStartTime.addingTimeInterval(seconds)
        } else if option == .custom, formEndTime <= formStartTime {
            formEndTime = formStartTime.addingTimeInterval(15 * 60)
        }
    }

    func setFormEndTime(_ newEnd: Date) {
        if editingEvent != nil { formTimingWasEdited = true }
        formDurationOption = .custom
        formEndTime = max(newEnd, formStartTime.addingTimeInterval(60))
    }

    func setFormAllDayMultiDay(_ isMultiDay: Bool) {
        if editingEvent != nil { formTimingWasEdited = true }
        formAllDayIsMultiDay = isMultiDay
        if isMultiDay, formAllDayEndDate < formStartTime {
            formAllDayEndDate = formStartTime
        }
    }

    func setFormAllDayEndDate(_ date: Date) {
        if editingEvent != nil { formTimingWasEdited = true }
        formAllDayEndDate = max(date, formStartTime)
    }

    func setFormRecurrence(_ recurrence: String) {
        if editingEvent != nil { formRecurrenceWasEdited = true }
        formRecurrence = recurrence
    }

    func addFormAttachment(
        _ document: SourceDocumentDTO,
        role: CalendarEventAttachmentRole = .other
    ) {
        formAttachmentDocuments[document.id] = document
        if !formAttachments.contains(where: { $0.documentId == document.id }) {
            formAttachments.append(
                CalendarEventAttachmentInput(documentId: document.id, role: role)
            )
        }
        syncLegacyPrimaryAttachment()
    }

    func removeFormAttachment(documentId: String) {
        formAttachments.removeAll { $0.documentId == documentId }
        formAttachmentDocuments[documentId] = nil
        syncLegacyPrimaryAttachment()
    }

    func setFormAttachmentRole(
        documentId: String,
        role: CalendarEventAttachmentRole
    ) {
        guard let index = formAttachments.firstIndex(where: {
            $0.documentId == documentId
        }) else { return }
        formAttachments[index].role = role
        syncLegacyPrimaryAttachment()
    }

    func documentForFormAttachment(_ attachment: CalendarEventAttachmentInput) -> SourceDocumentDTO? {
        formAttachmentDocuments[attachment.documentId]
    }

    private func syncLegacyPrimaryAttachment() {
        formSourceDocumentId = formAttachments.first?.documentId
        formSourceDocument = formAttachments.first.flatMap {
            formAttachmentDocuments[$0.documentId]
        }
    }

    private func attachmentInputs(for event: CalendarEventDTO) -> [CalendarEventAttachmentInput] {
        if !event.attachments.isEmpty {
            return event.attachments
                .sorted { $0.position < $1.position }
                .map { CalendarEventAttachmentInput(documentId: $0.id, role: $0.role) }
        }
        guard let documentId = event.sourceDocumentId else { return [] }
        return [CalendarEventAttachmentInput(documentId: documentId, role: .other)]
    }

    private func attachmentDocuments(for event: CalendarEventDTO) -> [String: SourceDocumentDTO] {
        var documents = Dictionary(
            uniqueKeysWithValues: event.attachments.map { ($0.id, $0.document) }
        )
        if let document = event.sourceDocument {
            documents[document.id] = document
        }
        return documents
    }

    private func optimisticAttachmentDTOs() -> [CalendarEventAttachmentDTO] {
        formAttachments.enumerated().compactMap { index, attachment in
            guard let document = formAttachmentDocuments[attachment.documentId] else {
                return nil
            }
            return CalendarEventAttachmentDTO(
                relationId: "local:\(attachment.documentId)",
                role: attachment.role,
                position: index,
                id: document.id,
                title: document.title,
                originalFilename: document.originalFilename,
                mediaType: document.mediaType,
                fileSize: document.fileSize,
                downloadUrl: document.downloadUrl
            )
        }
    }

    // MARK: - Private

    private let apiClient: APIClient
    private let defaults: UserDefaults
    private let syncManager: SyncManager
    private var modelContext: ModelContext?
    private var pendingCreateRequest: CreateCalendarEventRequest?
    private var eventLoadGeneration = 0
    private var fitnessOwnerUserId: String?
    private var fitnessPreferenceIdentity: String?
    private var fitnessIntentsByEventId: [String: FitnessDeepLinkIntent] = [:]
    private var stagedFacilityImport: SchoolTimetableStaging.StagedFile?
    private var stagedToastImport: SchoolTimetableStaging.StagedFile?

    init(
        apiClient: APIClient = .shared,
        defaults: UserDefaults = .standard,
        syncManager: SyncManager? = nil
    ) {
        self.apiClient = apiClient
        self.defaults = defaults
        self.syncManager = syncManager ?? .shared
    }

    deinit {
        let facility = stagedFacilityImport
        let toast = stagedToastImport
        Task {
            if let facility { await SchoolTimetableStaging.remove(facility) }
            if let toast { await SchoolTimetableStaging.remove(toast) }
        }
    }

    func configureFitnessCalendar(
        ownerUserId: String?,
        localIdentity: String? = FitnessDatabase.shared.activeIdentity
    ) {
        fitnessOwnerUserId = ownerUserId
        fitnessPreferenceIdentity = localIdentity
        guard let identity = localIdentity else { return }
        let plannedKey = OwnerScopedPreferences.fitnessCalendarPlanned(identity: identity)
        let completedKey = OwnerScopedPreferences.fitnessCalendarCompleted(identity: identity)
        showFitnessPlans = defaults.object(forKey: plannedKey) == nil ? true : defaults.bool(forKey: plannedKey)
        showCompletedFitness = defaults.bool(forKey: completedKey)
    }

    /// Server preferences follow the adult between devices. A missing endpoint
    /// or offline request deliberately leaves the local/default choice intact.
    func loadFitnessCalendarPreference() async {
        guard fitnessOwnerUserId != nil else { return }

        if hasPendingFitnessCalendarPreference {
            let pending = FitnessCalendarPreferenceDTO(
                showPlanned: showFitnessPlans,
                showCompleted: showCompletedFitness
            )
            guard let saved = await publishFitnessCalendarPreference(pending) else { return }
            applyFitnessCalendarPreference(saved)
            markFitnessCalendarPreferencePending(false)
            return
        }

        do {
            let preference: FitnessCalendarPreferenceDTO = try await apiClient.get(
                "/fitness/calendar-preferences",
                bypassCache: true
            )
            applyFitnessCalendarPreference(preference)
        } catch is CancellationError {
            return
        } catch {
            // Local owner-scoped preferences are the intentional offline fallback.
            Self.logger.info(
                "Fitness calendar preference refresh failed; retaining the local owner-scoped value."
            )
        }
    }

    func setFitnessCalendarVisibility(plans: Bool? = nil, completed: Bool? = nil) async {
        showFitnessPlans = plans ?? showFitnessPlans
        showCompletedFitness = completed ?? showCompletedFitness
        persistFitnessCalendarPreference()
        markFitnessCalendarPreferencePending(true)
        let requested = FitnessCalendarPreferenceDTO(
            showPlanned: showFitnessPlans,
            showCompleted: showCompletedFitness
        )
        async let savedPreference = publishFitnessCalendarPreference(requested)
        await loadEvents()
        if let savedPreference = await savedPreference {
            applyFitnessCalendarPreference(savedPreference)
            markFitnessCalendarPreferencePending(false)
        }
    }

    private func publishFitnessCalendarPreference(
        _ preference: FitnessCalendarPreferenceDTO
    ) async -> FitnessCalendarPreferenceDTO? {
        do {
            return try await apiClient.patch(
                "/fitness/calendar-preferences",
                body: preference
            )
        } catch is CancellationError {
            return nil
        } catch {
            // The pending flag is deliberately retained so a later load retries
            // publication without losing the user's local choice.
            Self.logger.info(
                "Fitness calendar preference publication failed; the pending local value will retry."
            )
            return nil
        }
    }

    func fitnessDeepLink(for event: CalendarEventDTO) -> FitnessDeepLinkIntent? {
        fitnessIntentsByEventId[event.id]
    }

    private func applyFitnessCalendarPreference(_ preference: FitnessCalendarPreferenceDTO) {
        showFitnessPlans = preference.showPlanned
        showCompletedFitness = preference.showCompleted
        persistFitnessCalendarPreference()
    }

    private func persistFitnessCalendarPreference() {
        guard let identity = fitnessPreferenceIdentity else { return }
        defaults.set(
            showFitnessPlans,
            forKey: OwnerScopedPreferences.fitnessCalendarPlanned(identity: identity)
        )
        defaults.set(
            showCompletedFitness,
            forKey: OwnerScopedPreferences.fitnessCalendarCompleted(identity: identity)
        )
    }

    private var hasPendingFitnessCalendarPreference: Bool {
        guard let identity = fitnessPreferenceIdentity else { return false }
        return defaults.bool(
            forKey: OwnerScopedPreferences.fitnessCalendarPending(identity: identity)
        )
    }

    private func markFitnessCalendarPreferencePending(_ isPending: Bool) {
        guard let identity = fitnessPreferenceIdentity else { return }
        defaults.set(
            isPending,
            forKey: OwnerScopedPreferences.fitnessCalendarPending(identity: identity)
        )
    }

    // Cached date formatters for display
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func bindModelContext(_ context: ModelContext) {
        modelContext = context
        loadLocalCalendarEvents()
    }

    // MARK: - Computed Properties

    /// Returns events that fall on the currently selected date, sorted chronologically.
    var eventsForSelectedDate: [CalendarEventDTO] {
        return events
            .filter { eventOverlapsDay($0, containing: selectedDate) }
            .sorted { lhs, rhs in
                // All-day events sort before timed events
                if lhs.allDay != rhs.allDay { return lhs.allDay }
                let lhsDate = parseISO8601(lhs.startTime) ?? .distantPast
                let rhsDate = parseISO8601(rhs.startTime) ?? .distantPast
                return lhsDate < rhsDate
            }
    }

    /// Returns the 7 days of the week containing the selected date.
    var weekDays: [Date] {
        let calendar = Calendar.current
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            return []
        }
        return (0..<7).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: weekInterval.start)
        }
    }

    /// Returns the complete weeks displayed for the month containing `date`.
    ///
    /// The end is exclusive so it can be passed directly to the calendar API.
    func monthGridInterval(
        containing date: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        guard let monthInterval = calendar.dateInterval(of: .month, for: date),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start),
              let finalMonthDay = calendar.date(byAdding: .second, value: -1, to: monthInterval.end),
              let finalWeek = calendar.dateInterval(of: .weekOfYear, for: finalMonthDay) else {
            return nil
        }

        return DateInterval(start: firstWeek.start, end: finalWeek.end)
    }

    /// Returns every local day shown in the selected month's grid.
    func monthGridDates(calendar: Calendar = .current) -> [Date] {
        guard let interval = monthGridInterval(containing: selectedDate, calendar: calendar) else {
            return []
        }

        var dates: [Date] = []
        var date = interval.start
        while date < interval.end {
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                break
            }
            date = next
        }
        return dates
    }

    /// Localized weekday symbols ordered using the display calendar's first weekday.
    func monthWeekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let startIndex = max(0, min(calendar.firstWeekday - 1, symbols.count - 1))
        return Array(symbols[startIndex...]) + Array(symbols[..<startIndex])
    }

    /// The API range needed by the selected planner mode.
    func eventLoadInterval(calendar: Calendar = .current) -> DateInterval? {
        switch viewMode {
        case .month:
            return monthGridInterval(containing: selectedDate, calendar: calendar)
        case .day, .week:
            return calendar.dateInterval(of: .weekOfYear, for: selectedDate)
        case .year:
            return nil
        }
    }

    var hasLoadedCurrentEventRange: Bool {
        guard let requested = eventLoadInterval(),
              let loaded = loadedEventInterval else {
            return false
        }
        return loaded.start <= requested.start && loaded.end >= requested.end
    }

    /// Returns events for a given column and date, filtered by assignment.
    func eventsForColumn(
        _ columnId: String,
        on date: Date,
        calendar: Calendar = .current
    ) -> [CalendarEventDTO] {
        let dayEvents = events
            .filter { eventOverlapsDay($0, containing: date, calendar: calendar) }
            .sorted { lhs, rhs in
                if lhs.allDay != rhs.allDay { return lhs.allDay }
                return lhs.startTime < rhs.startTime
            }

        return dayEvents.filter { eventMatchesColumn($0, columnId: columnId) }
    }

    /// Builds one date-to-events map for a month grid render.
    func eventsByDay(
        for dates: [Date],
        columnId: String,
        calendar: Calendar = .current
    ) -> [Date: [CalendarEventDTO]] {
        let dayIntervals = dates.compactMap { date -> (Date, DateInterval)? in
            guard let interval = calendar.dateInterval(of: .day, for: date) else {
                return nil
            }
            return (interval.start, interval)
        }
        var result = Dictionary(
            uniqueKeysWithValues: dayIntervals.map { ($0.0, [CalendarEventDTO]()) }
        )

        for event in events where eventMatchesColumn(event, columnId: columnId) {
            guard let eventStart = eventBoundary(
                event.startTime,
                allDay: event.allDay,
                calendar: calendar
            ) else {
                continue
            }
            let eventEnd = event.endTime.flatMap {
                eventBoundary($0, allDay: event.allDay, calendar: calendar)
            }
            let hasUsableEnd = eventEnd.map { $0 > eventStart } == true

            for (dayKey, dayInterval) in dayIntervals {
                let overlaps: Bool
                if let eventEnd, hasUsableEnd {
                    overlaps = eventStart < dayInterval.end && eventEnd > dayInterval.start
                } else {
                    overlaps = eventStart >= dayInterval.start && eventStart < dayInterval.end
                }
                if overlaps {
                    result[dayKey, default: []].append(event)
                }
            }
        }

        for day in Array(result.keys) {
            result[day]?.sort { lhs, rhs in
                if lhs.allDay != rhs.allDay { return lhs.allDay }
                return lhs.startTime < rhs.startTime
            }
        }
        return result
    }

    /// Returns events for a specific person on a given date.
    func eventsForPerson(_ personId: String, on date: Date) -> [CalendarEventDTO] {
        return events.filter { event in
            eventOverlapsDay(event, containing: date)
                && (participantIDs(for: event).contains(personId)
                    || (event.affectedMemberIds ?? []).contains(personId))
        }.sorted { $0.startTime < $1.startTime }
    }

    /// Returns whether an event occupies any part of the specified local calendar day.
    ///
    /// Calendar intervals are half-open: an event ending exactly at midnight does not
    /// appear on the new day. This also matches the exclusive `DTEND` used by imported
    /// all-day iCalendar events. Events without a usable end remain visible on their
    /// start day only.
    func eventOverlapsDay(
        _ event: CalendarEventDTO,
        containing date: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard let day = calendar.dateInterval(of: .day, for: date),
              let eventStart = eventBoundary(
                  event.startTime,
                  allDay: event.allDay,
                  calendar: calendar
              ) else {
            return false
        }

        guard let endTime = event.endTime,
              let eventEnd = eventBoundary(
                  endTime,
                  allDay: event.allDay,
                  calendar: calendar
              ),
              eventEnd > eventStart else {
            return eventStart >= day.start && eventStart < day.end
        }

        return eventStart < day.end && eventEnd > day.start
    }

    /// Describes the portion of an event shown on one rendered calendar day.
    /// The event's original range remains available for detail views.
    func occurrenceTimeLabel(
        for event: CalendarEventDTO,
        on date: Date,
        calendar: Calendar = .current
    ) -> String {
        guard eventOverlapsDay(event, containing: date, calendar: calendar),
              let day = calendar.dateInterval(of: .day, for: date),
              let eventStart = eventBoundary(
                  event.startTime,
                  allDay: event.allDay,
                  calendar: calendar
              ) else {
            return ""
        }

        if event.allDay { return "All day" }

        let startLabel = shortTime(eventStart, calendar: calendar)
        guard let endTime = event.endTime,
              let eventEnd = eventBoundary(
                  endTime,
                  allDay: event.allDay,
                  calendar: calendar
              ),
              eventEnd > eventStart else {
            return startLabel
        }

        let startsOnDisplayedDay = eventStart >= day.start && eventStart < day.end
        if startsOnDisplayedDay {
            // Preserve the familiar range for an event contained within one day.
            // A multi-day occurrence shows only its start here; later entries make
            // the continuation explicit.
            if eventEnd < day.end {
                return "\(startLabel) - \(shortTime(eventEnd, calendar: calendar))"
            }
            return startLabel
        }

        if eventEnd <= day.end {
            if eventEnd == day.end { return "Until midnight" }
            return "Until \(shortTime(eventEnd, calendar: calendar))"
        }

        return "Continues"
    }

    /// Returns active routine pills for a specific date.
    func routinesForDate(_ date: Date) -> [ActiveRoutineDTO] {
        let dateString = Self.dateOnlyFormatter.string(from: date)
        return activeRoutines.filter { $0.date == dateString }
    }

    func handoffsForDate(_ date: Date) -> [HandoffOccurrenceDTO] {
        let dateString = Self.dateOnlyFormatter.string(from: date)
        return handoffs
            .filter { $0.date == dateString }
            .sorted { lhs, rhs in
                if lhs.timeOfDay != rhs.timeOfDay { return lhs.timeOfDay < rhs.timeOfDay }
                return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
    }

    /// Returns active routine pills for a specific person on a date.
    func routinesForPerson(_ personId: String, on date: Date) -> [ActiveRoutineDTO] {
        routinesForDate(date).filter { $0.personId == personId }
    }

    /// Returns active routine pills for all kids on a date.
    func routinesForKids(on date: Date) -> [ActiveRoutineDTO] {
        routinesForDate(date).filter { childIds.contains($0.personId) }
    }

    func routinesForSelectedColumn(on date: Date) -> [ActiveRoutineDTO] {
        guard let column = selectedColumnDef else { return routinesForDate(date) }
        switch column.kind {
        case .viewAll:
            return routinesForDate(date)
        case .person(let id):
            return routinesForPerson(id, on: date)
        case .kids:
            if let childId = selectedChildFilterId {
                return routinesForPerson(childId, on: date)
            }
            return routinesForKids(on: date)
        case .everyone:
            return []
        }
    }

    func tasksForSelectedColumn(on date: Date) -> [TaskDTO] {
        let tasks = tasksForDate(date)
        guard let column = selectedColumnDef else { return tasks }
        switch column.kind {
        case .viewAll:
            return tasks
        case .person(let id):
            return tasks.filter { task in
                task.assignedTo == id || task.assignees.contains(where: { $0.assigneeId == id })
            }
        case .kids:
            if let childId = selectedChildFilterId {
                return tasks.filter { task in
                    task.assignedTo == childId || task.assignees.contains(where: { $0.assigneeId == childId })
                }
            }
            return tasks.filter { task in
                task.assignedTo.map(childIds.contains) == true
                    || task.assignees.contains(where: { childIds.contains($0.assigneeId) })
            }
        case .everyone:
            return tasks.filter { $0.assignedTo == nil && $0.assignees.isEmpty }
        }
    }

    /// One calm, chronological plan for the selected family column. Untimed
    /// routines and tasks deliberately fall to the end under “Any time”.
    func dayPlanItems(on date: Date, calendar: Calendar = .current) -> [PlannerDayItem] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        var items: [PlannerDayItem] = []
        let visibleEvents = eventsForColumn(
            selectedColumnId,
            on: date,
            calendar: calendar
        )
        let toastEvents = visibleEvents
            .filter(\.isToastProjection)
            .sorted { $0.startTime < $1.startTime }
        let dayHandoffs = handoffsForDate(date)

        if !toastEvents.isEmpty || !dayHandoffs.isEmpty {
            let firstToastDate = toastEvents.first.flatMap {
                eventBoundary($0.startTime, allDay: false, calendar: calendar)
            }
            let firstHandoffDate = dayHandoffs.compactMap { handoff -> Date? in
                let parts = handoff.timeOfDay.split(separator: ":").compactMap { Int($0) }
                guard parts.count >= 2 else { return nil }
                return calendar.date(
                    bySettingHour: parts[0],
                    minute: parts[1],
                    second: 0,
                    of: day.start
                )
            }.min()
            items.append(
                PlannerDayItem(
                    id: "coordination:\(Self.dateOnlyFormatter.string(from: date))",
                    title: "Leave & pickup",
                    detail: nil,
                    timeLabel: "Plan",
                    sortDate: [firstToastDate, firstHandoffDate].compactMap { $0 }.min(),
                    sortRank: 15,
                    kind: .coordination(handoffs: dayHandoffs, toast: toastEvents)
                )
            )
        }

        for event in visibleEvents where !event.isToastProjection {
            let start = eventBoundary(event.startTime, allDay: event.allDay, calendar: calendar)
            items.append(
                PlannerDayItem(
                    id: "event:\(event.id)",
                    title: event.title,
                    detail: participantLabel(for: event),
                    timeLabel: occurrenceTimeLabel(for: event, on: date, calendar: calendar),
                    sortDate: event.allDay ? day.start : start,
                    sortRank: 20,
                    kind: .event(event)
                )
            )
        }

        let visibleEventIds = Set(
            visibleEvents.flatMap { [$0.id, $0.seriesId].compactMap { $0 } }
        )
        for suggestion in prepSuggestionsForDate(date, calendar: calendar)
        where visibleEventIds.contains(suggestion.eventId) {
            let eventStart = eventBoundary(
                suggestion.eventStart,
                allDay: suggestion.eventAllDay,
                calendar: calendar
            ) ?? day.start
            items.append(
                PlannerDayItem(
                    id: "prep:\(suggestion.id)",
                    title: "Pack for \(suggestion.eventTitle)",
                    detail: suggestion.items.joined(separator: ", "),
                    timeLabel: suggestion.eventAllDay
                        ? "Before you go" : formattedTime(suggestion.eventStart),
                    sortDate: eventStart,
                    sortRank: suggestion.eventAllDay ? 1 : 10,
                    kind: .prep(suggestion)
                )
            )
        }

        for routine in routinesForSelectedColumn(on: date) {
            let explicitMinutes = routine.timeOfDay.flatMap { value -> Int? in
                let parts = value.split(separator: ":").compactMap { Int($0) }
                guard parts.count >= 2 else { return nil }
                return parts[0] * 60 + parts[1]
            }
            let minutes = explicitMinutes ?? suggestedRoutineMinutes(routine.name)
            let time = minutes.flatMap {
                calendar.date(byAdding: .minute, value: $0, to: day.start)
            }
            let detail = [routine.personName, routine.location, routine.preparationNote]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " · ")
            items.append(
                PlannerDayItem(
                    id: "routine:\(routine.id)",
                    title: routine.name,
                    detail: detail,
                    timeLabel: time.map { shortTime($0, calendar: calendar) } ?? "Any time",
                    sortDate: time,
                    sortRank: 30,
                    kind: .routine(routine)
                )
            )
        }

        for task in tasksForSelectedColumn(on: date) {
            let parsedDue = task.dueDate.flatMap(ISODateParser.parse)
            let hasExactTime = (task.dueDate?.count ?? 0) > 10
            let time = hasExactTime ? parsedDue : nil
            items.append(
                PlannerDayItem(
                    id: "task:\(task.id)",
                    title: task.title,
                    detail: task.category,
                    timeLabel: time.map { shortTime($0, calendar: calendar) } ?? "Any time",
                    sortDate: time,
                    sortRank: 40,
                    kind: .task(task)
                )
            )
        }

        return items.sorted { lhs, rhs in
            switch (lhs.sortDate, rhs.sortDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                if lhs.sortRank != rhs.sortRank { return lhs.sortRank < rhs.sortRank }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    func prepSuggestionsForDate(
        _ date: Date,
        calendar: Calendar = .current
    ) -> [PrepPackSuggestionDTO] {
        plannerPrepSuggestions.filter { suggestion in
            guard let eventStart = eventBoundary(
                suggestion.eventStart,
                allDay: suggestion.eventAllDay,
                calendar: calendar
            ) else { return false }
            return calendar.isDate(eventStart, inSameDayAs: date)
        }
    }

    func prepSuggestions(for event: CalendarEventDTO) -> [PrepPackSuggestionDTO] {
        let eventIds = Set([event.id, event.seriesId].compactMap { $0 })
        return plannerPrepSuggestions.filter { suggestion in
            guard eventIds.contains(suggestion.eventId) else { return false }
            if event.isGeneratedOccurrence == true {
                return suggestion.occurrenceStart == event.startTime
                    || suggestion.eventStart == event.startTime
            }
            return true
        }
    }

    func relatedTasks(for event: CalendarEventDTO) -> [TaskDTO] {
        let eventIds = Set([event.id, event.seriesId].compactMap { $0 })
        return plannerTasks.filter { task in
            task.sourceEventId.map(eventIds.contains) == true
                && task.prepOccurrenceId == nil
        }
    }

    func preparationTasks(for event: CalendarEventDTO) -> [TaskDTO] {
        let eventIds = Set([event.id, event.seriesId].compactMap { $0 })
        return plannerTasks.filter { task in
            guard task.sourceEventId.map(eventIds.contains) == true,
                  task.prepOccurrenceId != nil else { return false }
            guard let occurrenceValue = task.prepOccurrenceStart,
                  let occurrence = ISODateParser.parse(occurrenceValue),
                  let eventStart = ISODateParser.parse(event.startTime) else {
                return event.seriesId == nil
            }
            return abs(occurrence.timeIntervalSince(eventStart)) < 1
        }
    }

    func applyPrepSuggestion(_ suggestion: PrepPackSuggestionDTO) async {
        guard prepBusyId == nil else { return }
        prepBusyId = suggestion.id
        defer { prepBusyId = nil }
        do {
            let timezone = TimeZone.current.identifier
            let _: PrepPackApplyResponseDTO = try await apiClient.post(
                "/prep-packs/apply",
                body: PrepPackActionRequest(
                    templateId: suggestion.templateId,
                    eventId: suggestion.eventId,
                    occurrenceStart: suggestion.occurrenceStart,
                    timezone: timezone
                )
            )
            plannerPrepSuggestions.removeAll { $0.id == suggestion.id }
            plannerTasks = await fetchPlannerTasks()
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add preparation checklist.".localized
        }
    }

    func clashes(
        for event: CalendarEventDTO,
        calendar: Calendar = .current
    ) -> [CalendarEventDTO] {
        guard let target = eventInterval(for: event, calendar: calendar) else { return [] }
        let targetPeople = participantIDs(for: event)
        return events.filter { candidate in
            guard candidate.id != event.id,
                  !(candidate.seriesId == event.seriesId
                    && candidate.startTime == event.startTime),
                  !((event.isToastProjection && candidate.isSchoolClubProjection)
                    || (event.isSchoolClubProjection && candidate.isToastProjection)),
                  let interval = eventInterval(for: candidate, calendar: calendar),
                  target.start < interval.end,
                  interval.start < target.end else { return false }
            let people = participantIDs(for: candidate)
            return targetPeople.isEmpty || people.isEmpty
                || !targetPeople.isDisjoint(with: people)
        }.sorted { $0.startTime < $1.startTime }
    }

    private func eventInterval(
        for event: CalendarEventDTO,
        calendar: Calendar
    ) -> DateInterval? {
        guard let start = eventBoundary(
            event.startTime,
            allDay: event.allDay,
            calendar: calendar
        ) else { return nil }
        let explicitEnd = event.endTime.flatMap {
            eventBoundary($0, allDay: event.allDay, calendar: calendar)
        }
        let fallback = calendar.date(
            byAdding: event.allDay ? .day : .minute,
            value: 1,
            to: start
        ) ?? start.addingTimeInterval(60)
        return DateInterval(start: start, end: max(explicitEnd ?? fallback, fallback))
    }

    private func suggestedRoutineMinutes(_ name: String) -> Int? {
        let value = name.lowercased()
        if value.contains("morning") || value.contains("breakfast")
            || value.contains("school") { return 7 * 60 }
        if value.contains("homework") || value.contains("after school") { return 16 * 60 }
        if value.contains("bed") || value.contains("bath")
            || value.contains("evening") { return 19 * 60 }
        return nil
    }

    /// Returns "W", "H", or nil for a column header based on term status.
    /// For individual person columns: shows "W" or "H" when mixed, nil when all_same.
    /// For "All" column: shows "H" only when all_same and all on holiday.
    func termBubble(forPersonId personId: String?) -> String? {
        // "All" or "Everyone" column (personId is nil or empty)
        guard let personId = personId, !personId.isEmpty else {
            if termAllSame {
                // Check if everyone is on holiday
                if let first = termStatuses.values.first, !first {
                    return "H"
                }
            }
            return nil
        }
        // Individual person column
        if termAllSame { return nil }
        guard let inTerm = termStatuses[personId] else { return nil }
        return inTerm ? "W" : "H"
    }

    /// Returns events grouped by day for the current week, filtered by the selected column.
    var weekDayEvents: [(date: Date, events: [CalendarEventDTO])] {
        weekDays.map { date in
            (date: date, events: eventsForColumn(selectedColumnId, on: date))
        }
    }

    // MARK: - Actions

    /// Moves the selected date by whole calendar months while clamping short months.
    func moveMonth(by value: Int, calendar: Calendar = .current) {
        guard value != 0,
              let currentMonth = calendar.dateInterval(of: .month, for: selectedDate),
              let targetMonth = calendar.date(
                  byAdding: .month,
                  value: value,
                  to: currentMonth.start
              ),
              let targetDayRange = calendar.range(of: .day, in: .month, for: targetMonth) else {
            return
        }

        let currentDay = calendar.component(.day, from: selectedDate)
        let clampedDay = min(currentDay, targetDayRange.count)
        var components = calendar.dateComponents([.year, .month], from: targetMonth)
        components.day = clampedDay
        components.hour = 12

        if let date = calendar.date(from: components) {
            selectedDate = date
            selectedYear = calendar.component(.year, from: date)
        }
    }

    /// Selects a date in Month without leaving the overview.
    func selectMonthDate(_ date: Date, calendar: Calendar = .current) {
        selectedDate = date
        selectedYear = calendar.component(.year, from: date)
    }

    /// Opens the complete daily planner for the currently selected month date.
    func openSelectedDateInDayView() {
        viewMode = .day
    }

    /// Re-anchors the active calendar mode to today.
    func goToToday(_ now: Date = Date(), calendar: Calendar = .current) {
        selectedDate = now
        selectedYear = calendar.component(.year, from: now)
    }

    /// Loads family members from the API.
    func loadFamilyMembers() async {
        familyMembersLoadFailed = false
        do {
            let result: [FamilyMemberDTO] = try await apiClient.get("/family/members")
            familyMembers = result
            hasLoadedFamilyMembers = true
        } catch {
            familyMembersLoadFailed = true
            hasLoadedFamilyMembers = false
        }
    }

    /// Loads the current adult's Calendar visibility choices. A 403 simply
    /// means Finance is not enabled, so Calendar remains fully usable.
    func loadFinanceProjectionPreference() async {
        do {
            let preference: FinanceProjectionPreferenceDTO = try await apiClient.get(
                "/finance/projection-preferences"
            )
            financeProjectionPreference = preference
        } catch {
            financeProjectionPreference = nil
        }
    }

    func setFinanceProjectionVisibility(
        showMoney: Bool? = nil,
        showDeliveries: Bool? = nil
    ) async {
        guard let current = financeProjectionPreference,
              !isUpdatingFinanceProjectionPreference else { return }
        let requested = FinanceProjectionPreferenceDTO(
            showMoney: showMoney ?? current.showMoney,
            showDeliveries: showDeliveries ?? current.showDeliveries
        )
        financeProjectionPreference = requested
        isUpdatingFinanceProjectionPreference = true
        defer { isUpdatingFinanceProjectionPreference = false }
        do {
            let saved: FinanceProjectionPreferenceDTO = try await apiClient.patch(
                "/finance/projection-preferences",
                body: requested
            )
            financeProjectionPreference = saved
            await loadEvents()
        } catch let error as APIError {
            financeProjectionPreference = current
            errorMessage = error.errorDescription
        } catch {
            financeProjectionPreference = current
            errorMessage = "Calendar visibility could not be saved. Please try again.".localized
        }
    }

    /// Loads the signed-in adult's optional Example School Calendar layers. The Today
    /// quick fact is independent, so a failed preference request never hides it.
    func loadFacilityCalendarPreference() async {
        do {
            let preference: FacilityCalendarPreferenceDTO = try await apiClient.get(
                "/facilities/calendar-preferences",
                bypassCache: true
            )
            facilityCalendarPreference = preference
        } catch {
            facilityCalendarPreference = nil
        }
    }

    func setFacilityCalendarVisibility(
        showFamilySwimming: Bool? = nil,
        showPersonalFacilities: Bool? = nil
    ) async {
        guard let current = facilityCalendarPreference,
              !isUpdatingFacilityCalendarPreference else { return }
        let requested = FacilityCalendarPreferenceDTO(
            showFamilySwimming: showFamilySwimming ?? current.showFamilySwimming,
            showPersonalFacilities: showPersonalFacilities ?? current.showPersonalFacilities
        )
        facilityCalendarPreference = requested
        isUpdatingFacilityCalendarPreference = true
        defer { isUpdatingFacilityCalendarPreference = false }
        do {
            let saved: FacilityCalendarPreferenceDTO = try await apiClient.patch(
                "/facilities/calendar-preferences",
                body: requested
            )
            facilityCalendarPreference = saved
            loadedEventInterval = nil
            await loadEvents()
        } catch let error as APIError {
            facilityCalendarPreference = current
            errorMessage = error.errorDescription
        } catch {
            facilityCalendarPreference = current
            errorMessage = "Example School calendar visibility could not be saved. Please try again.".localized
        }
    }

    /// Streams the security-scoped picker result into a protected, bounded
    /// staging file off the main actor, then asks the server for a deterministic,
    /// non-mutating parse.
    func previewSchoolTimetable(at sourceURL: URL) async {
        guard !facilityImportBusy else { return }
        discardFacilityImport()
        facilityImportBusy = true
        facilityImportError = nil
        facilityImportNotice = nil
        defer { facilityImportBusy = false }

        var stagedFile: SchoolTimetableStaging.StagedFile?
        do {
            let staged = try await SchoolTimetableStaging.stageSecurityScopedFile(
                at: sourceURL
            )
            stagedFile = staged
            let preview: FacilityImportPreviewDTO = try await apiClient.uploadMultipart(
                "/facilities/example_school/preview",
                fileURL: staged.url,
                filename: staged.originalFilename,
                mediaType: SchoolTimetableStaging.mediaType,
                fields: [:]
            )
            try Task.checkCancellation()
            stagedFacilityImport = staged
            stagedFile = nil
            facilityImportPreview = preview
            if preview.alreadyImported {
                facilityImportNotice = "This timetable is already current."
            }
        } catch let error as APIError {
            if let stagedFile { await SchoolTimetableStaging.remove(stagedFile) }
            facilityImportError = error.errorDescription
                ?? "The timetable could not be reviewed. Please try again."
        } catch let error as SchoolTimetableStagingError {
            if let stagedFile { await SchoolTimetableStaging.remove(stagedFile) }
            facilityImportError = error.errorDescription
        } catch is CancellationError {
            if let stagedFile { await SchoolTimetableStaging.remove(stagedFile) }
        } catch {
            if let stagedFile { await SchoolTimetableStaging.remove(stagedFile) }
            facilityImportError = "The timetable could not be reviewed. Please try again."
        }
    }

    /// Confirms exactly the bytes reviewed above. The SHA-256 field lets the
    /// server reject a changed file before any document or schedule is stored.
    @discardableResult
    func confirmSchoolTimetable() async -> Bool {
        guard !facilityImportBusy,
              let preview = facilityImportPreview,
              preview.canConfirm,
              let stagedFile = stagedFacilityImport else { return false }
        facilityImportBusy = true
        facilityImportError = nil
        defer { facilityImportBusy = false }
        do {
            let result: FacilityImportResultDTO = try await apiClient.uploadMultipart(
                "/facilities/example_school/import",
                fileURL: stagedFile.url,
                filename: stagedFile.originalFilename,
                mediaType: SchoolTimetableStaging.mediaType,
                fields: ["expected_sha256": preview.sha256]
            )
            facilityImportNotice = result.imported
                ? "Example School swimming and weights times are up to date."
                : "This Example School timetable was already current."
            removeStagedFacilityImport()
            facilityImportPreview = nil
            loadedEventInterval = nil
            await loadEvents()
            return true
        } catch let error as APIError {
            facilityImportError = error.errorDescription
                ?? "The timetable could not be imported. Please try again."
        } catch {
            facilityImportError = "The timetable could not be imported. Please try again."
        }
        return false
    }

    func discardFacilityImport() {
        guard !facilityImportBusy else { return }
        removeStagedFacilityImport()
        facilityImportPreview = nil
        facilityImportError = nil
    }

    func reportFacilityPickerError(_ error: Error) {
        facilityImportError = "The timetable could not be opened: \(error.localizedDescription)"
    }

    private func removeStagedFacilityImport() {
        let stagedFile = stagedFacilityImport
        stagedFacilityImport = nil
        guard let stagedFile else { return }
        Task {
            await SchoolTimetableStaging.remove(stagedFile)
        }
    }

    func loadSchoolClubs() async {
        guard !schoolClubBusy else { return }
        schoolClubBusy = true
        schoolClubError = nil
        defer { schoolClubBusy = false }
        do {
            let clubs: [SchoolClubDTO] = try await apiClient.get(
                "/clubs/",
                bypassCache: true
            )
            schoolClubs = clubs
        } catch let error as APIError {
            schoolClubError = error.errorDescription ?? "Clubs could not be loaded."
        } catch {
            schoolClubError = "Clubs could not be loaded."
        }
    }

    @discardableResult
    func saveSchoolClub(
        existing: SchoolClubDTO?,
        name: String,
        childId: String,
        weekday: Int,
        startTime: String,
        endTime: String
    ) async -> Bool {
        guard !schoolClubBusy else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !childId.isEmpty, endTime > startTime else {
            schoolClubError = "Check the club, child and times."
            return false
        }
        schoolClubBusy = true
        schoolClubError = nil
        defer { schoolClubBusy = false }
        do {
            let timestamp = ISODateParser.stringNoFractional(from: Date())
            let saved: SchoolClubDTO
            if let existing {
                saved = try await apiClient.put(
                    "/clubs/\(existing.id)",
                    body: SchoolClubUpdateRequest(
                        name: trimmedName,
                        childId: childId,
                        weekday: weekday,
                        startTime: startTime,
                        endTime: endTime,
                        clientId: try apiClient.clientId,
                        clientTimestamp: timestamp
                    )
                )
            } else {
                let id = UUID().uuidString.lowercased()
                saved = try await apiClient.post(
                    "/clubs/",
                    body: SchoolClubCreateRequest(
                        id: id,
                        name: trimmedName,
                        childId: childId,
                        weekday: weekday,
                        startTime: startTime,
                        endTime: endTime,
                        clientId: try apiClient.clientId,
                        clientTimestamp: timestamp
                    )
                )
            }
            schoolClubs.removeAll { $0.id == saved.id }
            schoolClubs.append(saved)
            schoolClubs.sort {
                ($0.childName, $0.weekday, $0.startTime)
                    < ($1.childName, $1.weekday, $1.startTime)
            }
            loadedEventInterval = nil
            await loadEvents()
            return true
        } catch let error as APIError {
            schoolClubError = error.errorDescription ?? "The club could not be saved."
        } catch {
            schoolClubError = "The club could not be saved."
        }
        return false
    }

    @discardableResult
    func deleteSchoolClub(_ club: SchoolClubDTO) async -> Bool {
        guard !schoolClubBusy else { return false }
        schoolClubBusy = true
        schoolClubError = nil
        defer { schoolClubBusy = false }
        do {
            try await apiClient.delete("/clubs/\(club.id)")
            schoolClubs.removeAll { $0.id == club.id }
            loadedEventInterval = nil
            await loadEvents()
            return true
        } catch let error as APIError {
            schoolClubError = error.errorDescription ?? "The club could not be removed."
        } catch {
            schoolClubError = "The club could not be removed."
        }
        return false
    }

    @discardableResult
    func changeSchoolClubOccurrence(_ event: CalendarEventDTO) async -> Bool {
        guard !schoolClubBusy,
              let clubId = event.managedSource?.sourceId,
              let start = ISODateParser.parse(event.startTime) else { return false }
        schoolClubBusy = true
        schoolClubError = nil
        defer { schoolClubBusy = false }
        let occurrenceDate = Self.dateOnlyFormatter.string(from: start)
        do {
            if event.isCancelledSchoolClub {
                let restored: SchoolClubCancellationResponseDTO = try await apiClient.deleteReturning(
                    "/clubs/\(clubId)/dates/\(occurrenceDate)/cancel"
                )
                _ = restored
            } else {
                let cancelled: SchoolClubCancellationResponseDTO = try await apiClient.put(
                    "/clubs/\(clubId)/dates/\(occurrenceDate)/cancel",
                    body: SchoolClubCancellationRequest(
                        clientId: try apiClient.clientId,
                        clientTimestamp: ISODateParser.stringNoFractional(from: Date())
                    )
                )
                _ = cancelled
            }
            loadedEventInterval = nil
            await loadEvents()
            return true
        } catch let error as APIError {
            schoolClubError = error.errorDescription ?? "That club date could not be changed."
        } catch {
            schoolClubError = "That club date could not be changed."
        }
        return false
    }

    func loadToastImportStatus() async {
        guard !toastImportBusy else { return }
        toastImportBusy = true
        toastImportError = nil
        defer { toastImportBusy = false }
        do {
            let status: [ToastImportStatusDTO] = try await apiClient.get(
                "/toast-club/status",
                bypassCache: true
            )
            toastImportStatus = status
        } catch let error as APIError {
            toastImportError = error.errorDescription ?? "Toast bookings could not be loaded."
        } catch {
            toastImportError = "Toast bookings could not be loaded."
        }
    }

    func previewToastBooking(at sourceURL: URL) async {
        guard !toastImportBusy else { return }
        discardToastImport()
        toastImportBusy = true
        toastImportError = nil
        toastImportNotice = nil
        defer { toastImportBusy = false }
        var stagedFile: SchoolTimetableStaging.StagedFile?
        do {
            let staged = try await SchoolTimetableStaging.stageSecurityScopedFile(at: sourceURL)
            stagedFile = staged
            let preview: ToastImportPreviewDTO = try await apiClient.uploadMultipart(
                "/toast-club/preview",
                fileURL: staged.url,
                filename: "toast-booking.docx",
                mediaType: SchoolTimetableStaging.mediaType,
                fields: [:]
            )
            try Task.checkCancellation()
            stagedToastImport = staged
            stagedFile = nil
            toastImportPreview = preview
            if preview.alreadyImported {
                toastImportNotice = "This form is already current."
            }
        } catch let error as APIError {
            if let stagedFile { await SchoolTimetableStaging.remove(stagedFile) }
            toastImportError = error.errorDescription ?? "The Toast form could not be reviewed."
        } catch is CancellationError {
            if let stagedFile { await SchoolTimetableStaging.remove(stagedFile) }
        } catch {
            if let stagedFile { await SchoolTimetableStaging.remove(stagedFile) }
            toastImportError = "The Toast form could not be reviewed."
        }
    }

    @discardableResult
    func confirmToastBooking() async -> Bool {
        guard !toastImportBusy,
              let preview = toastImportPreview,
              preview.canConfirm,
              let stagedFile = stagedToastImport else { return false }
        toastImportBusy = true
        toastImportError = nil
        defer { toastImportBusy = false }
        do {
            let result: ToastImportResultDTO = try await apiClient.uploadMultipart(
                "/toast-club/import",
                fileURL: stagedFile.url,
                filename: "toast-booking.docx",
                mediaType: SchoolTimetableStaging.mediaType,
                fields: [
                    "expected_sha256": preview.sha256,
                    "client_id": try apiClient.clientId,
                    "client_timestamp": ISODateParser.stringNoFractional(from: Date())
                ]
            )
            toastImportNotice = result.imported
                ? "\(result.preview.childName)’s Toast dates are up to date."
                : "This form was already current."
            removeStagedToastImport()
            toastImportPreview = nil
            loadedEventInterval = nil
            await loadEvents()
            let status: [ToastImportStatusDTO] = try await apiClient.get(
                "/toast-club/status",
                bypassCache: true
            )
            toastImportStatus = status
            return true
        } catch let error as APIError {
            toastImportError = error.errorDescription ?? "The Toast form could not be imported."
        } catch {
            toastImportError = "The Toast form could not be imported."
        }
        return false
    }

    func discardToastImport() {
        guard !toastImportBusy else { return }
        removeStagedToastImport()
        toastImportPreview = nil
        toastImportError = nil
    }

    func reportToastPickerError(_ error: Error) {
        toastImportError = "The Toast form could not be opened: \(error.localizedDescription)"
    }

    private func removeStagedToastImport() {
        let stagedFile = stagedToastImport
        stagedToastImport = nil
        guard let stagedFile else { return }
        Task { await SchoolTimetableStaging.remove(stagedFile) }
    }

    func loadHandoffSchedule() async {
        guard !handoffBusy else { return }
        handoffBusy = true
        handoffError = nil
        defer { handoffBusy = false }
        do {
            let response: HandoffScheduleResponseDTO = try await apiClient.get(
                "/routines/handoffs/schedule",
                bypassCache: true
            )
            handoffSchedule = response.items
        } catch let error as APIError {
            handoffError = error.errorDescription
                ?? "Handoffs could not be loaded. Please try again."
        } catch {
            handoffError = "Handoffs could not be loaded. Please try again."
        }
    }

    @discardableResult
    func saveHandoffSchedule(_ items: [HandoffScheduleItemRequest]) async -> Bool {
        guard !handoffBusy else { return false }
        handoffBusy = true
        handoffError = nil
        defer { handoffBusy = false }
        do {
            let response: HandoffScheduleResponseDTO = try await apiClient.put(
                "/routines/handoffs/schedule",
                body: HandoffScheduleUpdateRequest(
                    items: items,
                    clientId: try apiClient.clientId,
                    clientTimestamp: ISODateParser.stringNoFractional(from: Date())
                )
            )
            handoffSchedule = response.items
            loadedEventInterval = nil
            await loadEvents()
            return true
        } catch let error as APIError {
            handoffError = error.errorDescription
                ?? "Handoffs could not be saved. Please try again."
        } catch {
            handoffError = "Handoffs could not be saved. Please try again."
        }
        return false
    }

    @discardableResult
    func changeHandoff(
        _ handoff: HandoffOccurrenceDTO,
        timeOfDay: String,
        cancelled: Bool = false
    ) async -> Bool {
        guard !handoffBusy else { return false }
        handoffBusy = true
        handoffError = nil
        defer { handoffBusy = false }
        do {
            let _: HandoffOccurrenceDTO? = try await apiClient.put(
                "/routines/handoffs/\(handoff.handoffId)/dates/\(handoff.date)",
                body: HandoffOccurrenceUpdateRequest(
                    timeOfDay: timeOfDay,
                    ownerUserId: handoff.kind == .workDeparture
                        ? handoff.termPersonId
                        : nil,
                    isCancelled: cancelled,
                    clientId: try apiClient.clientId,
                    clientTimestamp: ISODateParser.stringNoFractional(from: Date())
                )
            )
            loadedEventInterval = nil
            await loadEvents()
            return true
        } catch let error as APIError {
            handoffError = error.errorDescription
                ?? "That handoff could not be changed. Please try again."
        } catch {
            handoffError = "That handoff could not be changed. Please try again."
        }
        return false
    }

    @discardableResult
    func restoreWeeklyHandoff(_ handoff: HandoffOccurrenceDTO) async -> Bool {
        guard !handoffBusy else { return false }
        handoffBusy = true
        handoffError = nil
        defer { handoffBusy = false }
        do {
            let _: HandoffOccurrenceDTO? = try await apiClient.deleteReturning(
                "/routines/handoffs/\(handoff.handoffId)/dates/\(handoff.date)"
            )
            loadedEventInterval = nil
            await loadEvents()
            return true
        } catch let error as APIError {
            handoffError = error.errorDescription
                ?? "The weekly handoff could not be restored."
        } catch {
            handoffError = "The weekly handoff could not be restored."
        }
        return false
    }

    /// Loads planner data for the visible day/week or complete month grid.
    func loadEvents() async {
        let calendar = Calendar.current
        guard let requestedInterval = eventLoadInterval(calendar: calendar) else {
            return
        }

        eventLoadGeneration += 1
        let generation = eventLoadGeneration

        let startString = ISODateParser.stringNoFractional(from: requestedInterval.start)
        let endString = ISODateParser.stringNoFractional(from: requestedInterval.end)

        isLoading = true
        errorMessage = nil

        let rangeStart = Self.dateOnlyFormatter.string(from: requestedInterval.start)
        let inclusiveRangeEnd = calendar.date(
            byAdding: .day,
            value: -1,
            to: requestedInterval.end
        ) ?? requestedInterval.end
        let rangeEnd = Self.dateOnlyFormatter.string(from: inclusiveRangeEnd)
        let dateStr = Self.dateOnlyFormatter.string(from: selectedDate)
        async let plannerTasksResult = fetchPlannerTasks()
        async let prepSuggestionsResult = fetchPrepSuggestions()
        async let eventsResult = fetchCalendarEvents(start: startString, end: endString)
        async let fitnessLayerResult = fetchFitnessCalendarEvents(start: startString, end: endString)
        async let facilityLayerResult = fetchFacilityCalendarEvents(
            start: rangeStart,
            end: rangeEnd
        )
        async let routinesResult: [ActiveRoutineDTO] = apiClient.get(
            "/routines/active",
            queryItems: [
                URLQueryItem(name: "start", value: rangeStart),
                URLQueryItem(name: "end", value: rangeEnd)
            ]
        )
        async let handoffsResult: [HandoffOccurrenceDTO] = apiClient.get(
            "/routines/handoffs",
            queryItems: [
                URLQueryItem(name: "start", value: rangeStart),
                URLQueryItem(name: "end", value: rangeEnd)
            ]
        )
        async let termStatusResult: TermStatusResponseDTO = apiClient.get(
            "/routines/term-status",
            queryItems: [URLQueryItem(name: "date", value: dateStr)]
        )

        do {
            let fetchedEvents = try await eventsResult
            guard generation == eventLoadGeneration else { return }
            let durableEvents = mergePendingCalendarEvents(with: fetchedEvents)
            // Calendar records are the critical surface. Paint them before
            // optional Fitness, facilities, routine and preparation layers finish.
            events = durableEvents
            fitnessIntentsByEventId = [:]
            loadedEventInterval = requestedInterval
            isLoading = false

            let fitnessProjection = await fitnessLayerResult
            let facilityProjection = await facilityLayerResult
            guard generation == eventLoadGeneration else { return }
            events = durableEvents + fitnessProjection.events + facilityProjection
            fitnessIntentsByEventId = fitnessProjection.intentsByEventId
        } catch let error as APIError {
            guard generation == eventLoadGeneration else { return }
            errorMessage = error.errorDescription
            isLoading = false
        } catch {
            guard generation == eventLoadGeneration else { return }
            errorMessage = "Failed to load events. Please try again.".localized
            isLoading = false
        }

        // Load routines (non-fatal)
        do {
            let fetchedRoutines = try await routinesResult
            guard generation == eventLoadGeneration else { return }
            activeRoutines = fetchedRoutines
        } catch {
            guard generation == eventLoadGeneration else { return }
            // Non-fatal — calendar still works without routines
            activeRoutines = []
        }

        // Handoffs are an optional planner layer, so a connection problem must
        // never make the family calendar unusable.
        do {
            let fetchedHandoffs = try await handoffsResult
            guard generation == eventLoadGeneration else { return }
            handoffs = fetchedHandoffs
        } catch {
            guard generation == eventLoadGeneration else { return }
            handoffs = []
        }

        // Load term status for selected date (non-fatal)
        do {
            let statusResponse = try await termStatusResult
            guard generation == eventLoadGeneration else { return }
            termAllSame = statusResponse.allSame
            var statusMap: [String: Bool] = [:]
            for entry in statusResponse.statuses {
                statusMap[entry.personId] = entry.inTerm
            }
            termStatuses = statusMap
        } catch {
            guard generation == eventLoadGeneration else { return }
            termStatuses = [:]
            termAllSame = true
        }

        let fetchedTasks = await plannerTasksResult
        let fetchedPrepSuggestions = await prepSuggestionsResult
        guard generation == eventLoadGeneration else { return }
        plannerTasks = fetchedTasks
        plannerPrepSuggestions = fetchedPrepSuggestions

        isLoading = false
    }

    /// Avoids a network refresh when the selected day is already inside the loaded range.
    func loadEventsIfNeeded() async {
        guard !hasLoadedCurrentEventRange else { return }
        await loadEvents()
    }

    private func fetchCalendarEvents(
        start: String,
        end: String
    ) async throws -> [CalendarEventDTO] {
        let pageSize = 200
        let maximumEvents = 2_000
        var offset = 0
        var seen = Set<String>()
        var events: [CalendarEventDTO] = []

        while offset < maximumEvents {
            let page: [CalendarEventDTO] = try await apiClient.get(
                "/calendar/",
                queryItems: [
                    URLQueryItem(name: "start", value: start),
                    URLQueryItem(name: "end", value: end),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "limit", value: String(pageSize))
                ]
            )
            events.append(contentsOf: page.filter { seen.insert($0.id).inserted })
            guard page.count == pageSize else { break }
            offset += pageSize
        }

        return events
    }

    /// Converts only the server's deliberately redacted calendar-layer DTO.
    /// Private workout steps, notes, readiness and health context never enter
    /// the family calendar model or its cache.
    private func fetchFitnessCalendarEvents(start: String,end: String) async -> FitnessCalendarProjection {
        guard showFitnessPlans || showCompletedFitness else { return .empty }
        guard let identity = FitnessDatabase.shared.activeIdentity else { return .empty }
        let includeCompleted = showCompletedFitness
        do {
            let lease = try FitnessDatabase.shared.lease(for: identity)
            let layer = try await FitnessDatabase.shared.withLease(lease, operation: {
                try await FitnessActivityService.shared.calendarLayer(
                    start: start,
                    end: end,
                    includeCompleted: includeCompleted
                ).value
            })
            return projectFitnessCalendarItems(layer)
        } catch is CancellationError {
            return .empty
        } catch {
            // Fitness is an additive planner layer; the family calendar remains
            // usable and the next planner refresh retries the scoped read.
            Self.logger.info(
                "Fitness calendar layer was unavailable; rendering the family calendar without it."
            )
            return .empty
        }
    }

    /// Projects only redacted row data while retaining the opaque detail ID in
    /// a private navigation map. The ID never becomes calendar description text.
    func projectFitnessCalendarItems(
        _ layer: [FitnessCalendarLayerItem]
    ) -> FitnessCalendarProjection {
        var intents: [String: FitnessDeepLinkIntent] = [:]
        let projectedEvents = layer.compactMap { item -> CalendarEventDTO? in
            let completed = item.layerKind == "completed" || item.status == "completed"
            guard completed ? showCompletedFitness : showFitnessPlans else { return nil }
            let startTime = item.scheduledStartUtc ?? item.scheduledDate
                .map { "\($0)T00:00:00Z" }
            guard let startTime else { return nil }
            let eventId = "fitness-layer-\(item.id)"
            intents[eventId] = FitnessDeepLinkIntent(
                destination: completed ? .activities : .plan,
                targetId: item.detailId,
                actionKind: completed ? "open_activity" : "open_session"
            )
            let endTime = item.durationS.flatMap { duration in
                FitnessDatabase.date(startTime).map {
                    FitnessDatabase.dateString($0.addingTimeInterval(duration))
                }
            }
            let itemOwnerUserId = item.ownerUserId ?? fitnessOwnerUserId
            return CalendarEventDTO(
                id: eventId, title: item.displayTitle,
                description: nil, startTime: startTime, endTime: endTime,
                allDay: item.scheduledStartUtc == nil, recurrenceRule: nil,
                location: nil,
                familyMemberIds: itemOwnerUserId.map { [$0] },
                createdAt: startTime, updatedAt: startTime, createdBy: itemOwnerUserId,
                assignedTo: itemOwnerUserId, eventType: "fitness_\(item.layerKind)",
                sourceName: "Fitness", sourceColor: nil, readOnly: completed
            )
        }
        return FitnessCalendarProjection(
            events: projectedEvents,
            intentsByEventId: intents
        )
    }

    private func fetchFacilityCalendarEvents(
        start: String,
        end: String
    ) async -> [CalendarEventDTO] {
        guard let preference = facilityCalendarPreference,
              preference.showFamilySwimming || preference.showPersonalFacilities else {
            return []
        }
        do {
            let layer: [FacilityCalendarLayerItemDTO] = try await apiClient.get(
                "/facilities/calendar-layer",
                queryItems: [
                    URLQueryItem(name: "start", value: start),
                    URLQueryItem(name: "end", value: end),
                ]
            )
            return projectFacilityCalendarItems(layer)
        } catch is CancellationError {
            return []
        } catch {
            // This read-only layer is additive. Keep the core planner available
            // and retry it with the next normal event refresh.
            Self.logger.info(
                "Facility calendar layer was unavailable; rendering the core planner only."
            )
            return []
        }
    }

    /// Keeps imported availability read-only and owner-scoped while letting it
    /// use the same day/week/month rendering and person filters as other events.
    func projectFacilityCalendarItems(
        _ layer: [FacilityCalendarLayerItemDTO]
    ) -> [CalendarEventDTO] {
        layer.map { item in
            var event = CalendarEventDTO(
                id: "facility-layer-\(item.id)",
                title: item.displayTitle,
                description: nil,
                startTime: item.startTime,
                endTime: item.endTime,
                allDay: false,
                recurrenceRule: nil,
                location: item.location,
                familyMemberIds: item.ownerUserId.map { [$0] },
                createdAt: item.startTime,
                updatedAt: item.startTime,
                createdBy: item.ownerUserId,
                assignedTo: item.ownerUserId,
                eventType: "facility_\(item.layerKind)",
                sourceName: "Example School facilities",
                sourceColor: "#168AAD",
                readOnly: true
            )
            event.sourceDocumentId = item.sourceDocumentId
            return event
        }
    }

    private func fetchPlannerTasks() async -> [TaskDTO] {
        do {
            return try await apiClient.get(
                "/tasks/",
                queryItems: [
                    URLQueryItem(name: "status", value: "pending"),
                    URLQueryItem(name: "limit", value: "200"),
                ]
            )
        } catch {
            return []
        }
    }

    private func fetchPrepSuggestions() async -> [PrepPackSuggestionDTO] {
        do {
            return try await apiClient.get(
                "/prep-packs/suggestions",
                queryItems: [
                    URLQueryItem(
                        name: "timezone",
                        value: TimeZone.current.identifier
                    ),
                    URLQueryItem(name: "horizon_days", value: "14"),
                ]
            )
        } catch {
            return []
        }
    }

    /// Loads term dates and holiday dates for the yearly overview.
    func loadYearData() async {
        do {
            yearlyTermDates = try await apiClient.get("/routines/terms")
        } catch {
            yearlyTermDates = []
        }
        do {
            yearlyHolidayDates = try await apiClient.get(
                "/routines/holidays",
                queryItems: [URLQueryItem(name: "year", value: String(selectedYear))]
            )
        } catch {
            yearlyHolidayDates = []
        }
    }

    private func makeFormRequest(id: String) -> CreateCalendarEventRequest? {
        guard !formTitle.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a title for the event.".localized
            return nil
        }
        guard formWholeFamily || familyMembers.isEmpty || !formParticipantIDs.isEmpty else {
            errorMessage = "Choose at least one person who is going.".localized
            return nil
        }

        let selectedParticipants = familyMembers
            .filter { formParticipantIDs.contains($0.id) }
            .map(\.id)
        let requestParticipantIDs = formWholeFamily || familyMembers.isEmpty
            || selectedParticipants.count == familyMembers.count ? nil : selectedParticipants
        let selectedParticipantSet = Set(selectedParticipants)
        let affectedAdults = adults
            .filter {
                formAffectedMemberIDs.contains($0.id)
                    && !selectedParticipantSet.contains($0.id)
            }
            .map(\.id)
        let requestAffectedMemberIDs = affectedAdults.isEmpty ? nil : affectedAdults
        let requestAssignedTo = requestParticipantIDs?.count == 1
            ? requestParticipantIDs?.first : nil
        let requestAttachments: [CalendarEventAttachmentInput]
        if formSourceDocumentId != formAttachments.first?.documentId {
            if let documentId = formSourceDocumentId {
                requestAttachments = [
                    CalendarEventAttachmentInput(documentId: documentId, role: .other)
                ] + formAttachments.dropFirst()
            } else {
                requestAttachments = []
            }
        } else {
            requestAttachments = formAttachments
        }

        guard let timing = currentFormTiming() else { return nil }

        return CreateCalendarEventRequest(
            id: id,
            title: formTitle.trimmingCharacters(in: .whitespaces),
            description: formDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : formDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            startTime: timing.startTime,
            endTime: timing.endTime,
            allDay: timing.allDay,
            recurrenceRule: recurrenceRule(for: formStartTime),
            location: formLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : formLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            familyMemberIds: requestParticipantIDs,
            affectedMemberIds: requestAffectedMemberIDs,
            assignedTo: requestAssignedTo,
            sourceDocumentId: requestAttachments.first?.documentId,
            attachments: requestAttachments
        )
    }

    private func currentFormTiming() -> FormTiming? {
        if formAllDay {
            let endTime: String?
            if formAllDayIsMultiDay {
                let finalDay = max(formStartTime, formAllDayEndDate)
                let exclusiveEnd = Calendar.current.date(
                    byAdding: .day,
                    value: 1,
                    to: Calendar.current.startOfDay(for: finalDay)
                ) ?? finalDay
                endTime = Self.dateOnlyFormatter.string(from: exclusiveEnd)
            } else {
                endTime = nil
            }
            return FormTiming(
                startTime: Self.dateOnlyFormatter.string(from: formStartTime),
                endTime: endTime,
                allDay: true
            )
        }
        if formDurationOption != .none, formEndTime <= formStartTime {
            errorMessage = "End time must be after the start time.".localized
            return nil
        }
        return FormTiming(
            startTime: ISODateParser.stringNoFractional(from: formStartTime),
            endTime: formDurationOption == .none
                ? nil : ISODateParser.stringNoFractional(from: formEndTime),
            allDay: false
        )
    }

    func saveEvent() async {
        if editingEvent == nil {
            await createEvent()
        } else {
            await updateEvent()
        }
    }

    /// Creates a new calendar event using the current form fields.
    /// `onDurablySaved` runs as soon as the event is safe on-device, without
    /// making the presentation wait for the network acknowledgement.
    func createEvent(onDurablySaved: (() -> Void)? = nil) async {
        guard let request = makeFormRequest(
            id: pendingCreateRequest?.id ?? UUID().uuidString
        ) else { return }
        pendingCreateRequest = request

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // The sync protocol represents one legacy source document. Preserve the
        // existing network-only rule for richer multi-document transactions.
        if (request.attachments?.count ?? 0) > 1 {
            do {
                let created: CalendarEventDTO = try await apiClient.post(
                    "/calendar/",
                    body: request
                )
                events.append(created)
                showingAddEvent = false
                HapticManager.success()
                onDurablySaved?()
            } catch let error as APIError {
                if case .networkError = error {
                    errorMessage = "Connect to save several event documents together.".localized
                } else {
                    errorMessage = error.errorDescription
                }
            } catch {
                errorMessage = "Failed to create event. Please try again.".localized
            }
            return
        }

        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Event could not be saved securely on this device. Please try again.".localized
            return
        }
        let now = ISODateParser.stringNoFractional(from: Date())
        var optimistic = CalendarEventDTO(
            id: request.id,
            title: request.title,
            description: request.description,
            startTime: request.startTime,
            endTime: request.endTime,
            allDay: request.allDay,
            recurrenceRule: request.recurrenceRule,
            location: request.location,
            familyMemberIds: request.familyMemberIds,
            affectedMemberIds: request.affectedMemberIds,
            createdAt: now,
            updatedAt: now,
            createdBy: nil,
            assignedTo: request.assignedTo
        )
        optimistic.sourceDocumentId = request.sourceDocumentId
        optimistic.sourceDocument = formSourceDocument
        optimistic.attachments = optimisticAttachmentDTOs()
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: request.id,
            operation: .create,
            tableName: "calendar_events",
            recordId: request.id,
            payload: [
                "title": request.title,
                "description": request.description ?? NSNull(),
                "start_time": request.startTime,
                "end_time": request.endTime ?? NSNull(),
                "all_day": request.allDay ? 1 : 0,
                "recurrence_rule": request.recurrenceRule ?? NSNull(),
                "location": request.location ?? NSNull(),
                "family_member_ids": request.familyMemberIds ?? NSNull(),
                "affected_member_ids": request.affectedMemberIds ?? NSNull(),
                "assigned_to": request.assignedTo ?? NSNull(),
                "source_document_id": request.sourceDocumentId ?? NSNull(),
            ],
            expectedIdentityLease: identityLease
        ) {
            try Self.insertCalendarEvent(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            self?.replaceCalendarEvent(optimistic)
            self?.showingAddEvent = false
            HapticManager.success()
            onDurablySaved?()
        } transport: { [apiClient] in
            let value: CalendarEventDTO = try await apiClient.post(
                "/calendar/",
                body: request
            )
            return value
        } validateAcknowledgement: { value in
            value.id == request.id ? nil : "The server acknowledged a different event."
        } applyAcknowledgedResult: { value in
            try Self.upsertCalendarEvent(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            replaceCalendarEvent(value)
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = "No connection. Event queued and will sync when online.".localized
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Event was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Event was saved locally, but the server rejected it. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Event was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This event was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Event was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    /// Updates a normal/imported event or applies the explicitly selected scope
    /// to a generated recurrence occurrence.
    func updateEvent() async {
        guard let editingEvent,
              let (eventId, request) = makeUpdateRequest() else { return }
        if request.isEmpty {
            showingAddEvent = false
            resetForm()
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let isScopedOccurrence = editingEvent.isGeneratedOccurrence == true
            && editingEvent.seriesId != nil
        let isNetworkOnly = isScopedOccurrence
            || editingEvent.readOnly == true
            || request.includedFields.contains(.attachments)

        if isNetworkOnly {
            do {
                let updated: CalendarEventDTO
                if isScopedOccurrence {
                    guard let scope = editingRecurrenceScope,
                          let occurrenceRequest = occurrenceUpdateRequest(
                            for: editingEvent,
                            scope: scope,
                            updates: request
                          ) else {
                        errorMessage = "Choose which repeating events to edit.".localized
                        return
                    }
                    let response = try await apiClient.postHTTPResponse(
                        "/calendar/\(eventId)/occurrences/edit",
                        body: occurrenceRequest
                    )
                    updated = try decodeCalendarMutationResponse(response)
                } else {
                    updated = try await apiClient.put(
                        "/calendar/\(eventId)",
                        body: request
                    )
                }
                events.removeAll {
                    $0.id == editingEvent.id
                        || $0.id == eventId
                        || $0.seriesId == eventId
                }
                events.append(updated)
                showingAddEvent = false
                resetForm()
                loadedEventInterval = nil
                await loadEvents()
                HapticManager.success()
            } catch let error as APIError {
                if case .networkError = error, isScopedOccurrence {
                    errorMessage = "Connect to edit part of a repeating series.".localized
                } else if case .networkError = error,
                          request.includedFields.contains(.attachments) {
                    errorMessage = "Connect to change event documents.".localized
                } else if case .networkError = error, editingEvent.readOnly == true {
                    errorMessage = "Connect to edit an imported event for the first time.".localized
                } else {
                    errorMessage = error.errorDescription
                }
            } catch {
                errorMessage = "Failed to update event. Please try again.".localized
            }
            return
        }

        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Event changes could not be saved securely on this device. Please try again.".localized
            return
        }
        let optimistic = applying(request, to: editingEvent)
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: UUID().uuidString,
            operation: .update,
            tableName: "calendar_events",
            recordId: eventId,
            payload: request.offlinePayload,
            expectedIdentityLease: identityLease
        ) {
            try Self.upsertCalendarEvent(optimistic, in: modelContext)
        } onStaged: { [weak self] in
            guard let self else { return }
            self.events.removeAll {
                $0.id == editingEvent.id
                    || $0.id == eventId
                    || $0.seriesId == eventId
            }
            self.events.append(optimistic)
            self.showingAddEvent = false
            self.resetForm()
        } transport: { [apiClient] in
            let value: CalendarEventDTO = try await apiClient.put(
                "/calendar/\(eventId)",
                body: request
            )
            return value
        } validateAcknowledgement: { value in
            value.id == eventId ? nil : "The server acknowledged a different event."
        } applyAcknowledgedResult: { value in
            try Self.upsertCalendarEvent(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            replaceCalendarEvent(value, replacingSeriesID: eventId)
            loadedEventInterval = nil
            await loadEvents()
            HapticManager.success()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = "No connection. Event update queued and will sync when online.".localized
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Event changes were saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Event changes were saved locally, but the server rejected them. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Event changes were saved. Their server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "These event changes were not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Event changes were saved locally. Their exact replay state will recover automatically.".localized
        }
    }

    /// Returns the stored row targeted by a generated occurrence action.
    func deleteTargetID(for event: CalendarEventDTO) -> String {
        event.seriesId ?? event.id
    }

    @discardableResult
    func changeRugbyVenue(_ event: CalendarEventDTO) async -> CalendarEventDTO? {
        guard event.rugbyVenue == "home" || event.rugbyVenue == "away" else {
            errorMessage = "This rugby fixture does not have a venue to change.".localized
            return nil
        }
        let nextVenue = event.rugbyVenue == "home" ? "away" : "home"
        errorMessage = nil
        do {
            let updated: CalendarEventDTO = try await apiClient.put(
                "/calendar/rugby/fixtures/\(event.id)/venue",
                body: SchoolRugbyVenueRequest(venue: nextVenue)
            )
            replaceCalendarEvent(updated)
            HapticManager.success()
            return updated
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The fixture venue could not be changed.".localized
        }
        HapticManager.error()
        return nil
    }

    /// Deletes an event or the explicitly selected part of a repeating series.
    /// Removing an override reloads the unchanged imported source.
    func deleteEvent(
        _ event: CalendarEventDTO,
        recurrenceScope: CalendarRecurrenceMutationScope? = nil
    ) async {
        if event.isFitnessProjection {
            guard let intent = fitnessDeepLink(for: event),
                  intent.destination == .plan,
                  let targetId = intent.targetId else {
                errorMessage = "Completed workouts stay in your activity history.".localized
                return
            }
            isLoading = true
            errorMessage = nil
            defer { isLoading = false }
            do {
                try await FitnessRepository.shared.deletePlannedSession(targetId)
                events.removeAll { $0.id == event.id }
                fitnessIntentsByEventId[event.id] = nil
                HapticManager.success()
                do {
                    try await FitnessSyncService.shared.syncNow()
                } catch {
                    errorMessage = "Planned exercise deleted on this device and will sync when connected.".localized
                }
            } catch {
                errorMessage = error.localizedDescription
                HapticManager.error()
            }
            return
        }
        let id = deleteTargetID(for: event)
        guard event.readOnly != true else {
            errorMessage = "Imported source events cannot be deleted.".localized
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let isScopedOccurrence = event.isGeneratedOccurrence == true && event.seriesId != nil

        if isScopedOccurrence {
            do {
                guard let recurrenceScope,
                      let request = recurrenceDeleteRequest(
                        for: event,
                        scope: recurrenceScope
                      ) else {
                    errorMessage = "Choose which repeating events to delete.".localized
                    isLoading = false
                    return
                }
                let response = try await apiClient.postHTTPResponse(
                    "/calendar/\(id)/occurrences/delete",
                    body: request
                )
                try validateCalendarMutationResponse(response)
                events.removeAll { $0.id == id || $0.seriesId == id }
                loadedEventInterval = nil
                await loadEvents()
                HapticManager.success()
            } catch let error as APIError {
                if case .networkError = error {
                    errorMessage = "Connect to delete part of a repeating series.".localized
                } else {
                    errorMessage = error.errorDescription
                }
            } catch {
                errorMessage = "Failed to delete event. Please try again.".localized
            }
            return
        }

        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Event deletion could not be saved securely on this device. Please try again.".localized
            return
        }
        let outcome: SyncManager.DurableMutationOutcome<Void> = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: UUID().uuidString,
            operation: .delete,
            tableName: "calendar_events",
            recordId: id,
            payload: nil,
            expectedIdentityLease: identityLease
        ) {
            try Self.markCalendarEventDeleted(event, in: modelContext)
        } onStaged: { [weak self] in
            self?.events.removeAll { $0.id == id || $0.seriesId == id }
        } transport: { [apiClient] in
            try await apiClient.delete("/calendar/\(id)")
        } applyAcknowledgedResult: { _ in }

        switch outcome {
        case .acknowledged:
            loadedEventInterval = nil
            await loadEvents()
            HapticManager.success()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = "No connection. Deletion queued for sync.".localized
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Deletion was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Deletion was saved locally, but the server rejected it. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Deletion was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This deletion was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Deletion was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    func occurrenceUpdateRequest(
        for event: CalendarEventDTO,
        scope: CalendarRecurrenceMutationScope,
        updates: UpdateCalendarEventRequest
    ) -> UpdateCalendarOccurrenceRequest? {
        guard event.isGeneratedOccurrence == true, event.seriesId != nil else { return nil }
        return UpdateCalendarOccurrenceRequest(
            scope: scope,
            occurrenceStart: event.startTime,
            updates: updates
        )
    }

    func recurrenceDeleteRequest(
        for event: CalendarEventDTO,
        scope: CalendarRecurrenceMutationScope,
        now: Date = Date()
    ) -> DeleteCalendarOccurrenceRequest? {
        guard event.isGeneratedOccurrence == true, event.seriesId != nil else { return nil }
        let clientId: String
        do {
            clientId = try apiClient.clientId
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        return DeleteCalendarOccurrenceRequest(
            scope: scope,
            occurrenceStart: event.startTime,
            clientId: clientId,
            clientTimestamp: ISODateParser.stringNoFractional(from: now)
        )
    }

    private func validateCalendarMutationResponse(_ response: APIHTTPResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            // Server detail is optional presentation text; the HTTP status and
            // typed API error remain authoritative when decoding fails.
            let detail = try? decoder.decode(
                CalendarMutationErrorResponse.self,
                from: response.data
            ).detail
            throw APIError.serverError(statusCode: response.statusCode, message: detail)
        }
    }

    private func decodeCalendarMutationResponse<T: Decodable>(
        _ response: APIHTTPResponse
    ) throws -> T {
        try validateCalendarMutationResponse(response)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: response.data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    /// Builds a sparse update so editing a generated occurrence cannot move a
    /// series anchor or simplify a COUNT/UNTIL/INTERVAL rule by accident.
    func makeUpdateRequest(
        now: Date = Date()
    ) -> (eventId: String, request: UpdateCalendarEventRequest)? {
        guard let editingEvent else { return nil }
        if formPeopleWereEdited && !familyMembersAvailable {
            errorMessage = "Reload family members before changing who this event is for.".localized
            return nil
        }
        guard let formRequest = makeFormRequest(id: UUID().uuidString) else { return nil }

        var includedFields = Set<CalendarEventUpdateField>()
        if formRequest.title != editingInitialTitle { includedFields.insert(.title) }
        if formRequest.description != editingInitialDescription { includedFields.insert(.description) }
        if formRequest.location != editingInitialLocation { includedFields.insert(.location) }
        let currentTiming = FormTiming(
            startTime: formRequest.startTime,
            endTime: formRequest.endTime,
            allDay: formRequest.allDay
        )
        if formTimingWasEdited && currentTiming != editingInitialTiming {
            includedFields.formUnion([.startTime, .endTime, .allDay])
        }
        if formRecurrenceWasEdited && formRecurrence != editingInitialRecurrence {
            includedFields.insert(.recurrenceRule)
        }
        let peopleChanged = formWholeFamily != editingInitialWholeFamily
            || formParticipantIDs != editingInitialParticipantIDs
            || formAffectedMemberIDs != editingInitialAffectedMemberIDs
        if formPeopleWereEdited && peopleChanged {
            includedFields.formUnion([.familyMemberIds, .affectedMemberIds, .assignedTo])
        }
        if formRequest.sourceDocumentId != editingInitialSourceDocumentId {
            includedFields.insert(.sourceDocumentId)
        }
        if formRequest.attachments != editingInitialAttachments {
            includedFields.formUnion([.attachments, .sourceDocumentId])
        }

        let clientId: String
        do {
            clientId = try apiClient.clientId
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }

        return (
            editingEvent.seriesId ?? editingEvent.id,
            UpdateCalendarEventRequest(
                title: includedFields.contains(.title) ? formRequest.title : nil,
                description: includedFields.contains(.description) ? formRequest.description : nil,
                startTime: includedFields.contains(.startTime) ? formRequest.startTime : nil,
                endTime: includedFields.contains(.endTime) ? formRequest.endTime : nil,
                allDay: includedFields.contains(.allDay) ? formRequest.allDay : nil,
                recurrenceRule: includedFields.contains(.recurrenceRule) ? formRequest.recurrenceRule : nil,
                location: includedFields.contains(.location) ? formRequest.location : nil,
                familyMemberIds: includedFields.contains(.familyMemberIds) ? formRequest.familyMemberIds : nil,
                affectedMemberIds: includedFields.contains(.affectedMemberIds) ? formRequest.affectedMemberIds : nil,
                assignedTo: includedFields.contains(.assignedTo) ? formRequest.assignedTo : nil,
                sourceDocumentId: includedFields.contains(.sourceDocumentId) ? formRequest.sourceDocumentId : nil,
                attachments: includedFields.contains(.attachments) ? formRequest.attachments : nil,
                clientId: clientId,
                clientTimestamp: ISODateParser.stringNoFractional(from: now),
                includedFields: includedFields
            )
        )
    }

    private func applying(
        _ request: UpdateCalendarEventRequest,
        to event: CalendarEventDTO
    ) -> CalendarEventDTO {
        var updated = CalendarEventDTO(
            id: event.id,
            title: request.includedFields.contains(.title) ? request.title ?? event.title : event.title,
            description: request.includedFields.contains(.description) ? request.description : event.description,
            startTime: request.includedFields.contains(.startTime) ? request.startTime ?? event.startTime : event.startTime,
            endTime: request.includedFields.contains(.endTime) ? request.endTime : event.endTime,
            allDay: request.includedFields.contains(.allDay) ? request.allDay ?? event.allDay : event.allDay,
            recurrenceRule: request.includedFields.contains(.recurrenceRule) ? request.recurrenceRule : event.recurrenceRule,
            location: request.includedFields.contains(.location) ? request.location : event.location,
            familyMemberIds: request.includedFields.contains(.familyMemberIds) ? request.familyMemberIds : event.familyMemberIds,
            affectedMemberIds: request.includedFields.contains(.affectedMemberIds) ? request.affectedMemberIds : event.affectedMemberIds,
            createdAt: event.createdAt,
            updatedAt: request.clientTimestamp ?? event.updatedAt,
            createdBy: event.createdBy,
            assignedTo: request.includedFields.contains(.assignedTo) ? request.assignedTo : event.assignedTo
        )
        updated.seriesId = event.seriesId
        updated.isGeneratedOccurrence = event.isGeneratedOccurrence
        updated.calendarSourceId = event.calendarSourceId
        updated.sourceName = event.sourceName
        updated.sourceColor = event.sourceColor
        updated.rugbyVenue = event.rugbyVenue
        updated.rugbyVenueOverridden = event.rugbyVenueOverridden
        updated.readOnly = event.readOnly
        updated.overriddenEventId = event.overriddenEventId
        updated.managedSource = event.managedSource
        if request.includedFields.contains(.sourceDocumentId) {
            updated.sourceDocumentId = request.sourceDocumentId
            updated.sourceDocument = formSourceDocument?.id == request.sourceDocumentId
                ? formSourceDocument : nil
        } else {
            updated.sourceDocumentId = event.sourceDocumentId
            updated.sourceDocument = event.sourceDocument
        }
        if request.includedFields.contains(.attachments) {
            updated.attachments = optimisticAttachmentDTOs()
        } else {
            updated.attachments = event.attachments
        }
        return updated
    }

    private func replaceCalendarEvent(
        _ event: CalendarEventDTO,
        replacingSeriesID: String? = nil
    ) {
        let targetID = replacingSeriesID ?? event.id
        events.removeAll {
            $0.id == event.id || $0.id == targetID || $0.seriesId == targetID
        }
        events.append(event)
    }

    private static func insertCalendarEvent(
        _ event: CalendarEventDTO,
        in modelContext: ModelContext
    ) throws {
        let requestedID = event.id
        let matches = try modelContext.fetch(FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.isEmpty else { throw DurableCalendarError.duplicateLocalRecord }
        try upsertCalendarEvent(event, in: modelContext)
    }

    private static func upsertCalendarEvent(
        _ event: CalendarEventDTO,
        in modelContext: ModelContext
    ) throws {
        guard !event.id.isEmpty,
              !event.title.isEmpty,
              let startTime = ISODateParser.parse(event.startTime),
              let createdAt = ISODateParser.parse(event.createdAt),
              let updatedAt = ISODateParser.parse(event.updatedAt),
              event.endTime == nil || event.endTime.flatMap(ISODateParser.parse) != nil else {
            throw DurableCalendarError.invalidLocalRecord
        }
        let memberData = try JSONEncoder().encode(event.familyMemberIds ?? [])
        guard let familyMemberIDs = String(data: memberData, encoding: .utf8) else {
            throw DurableCalendarError.invalidLocalRecord
        }
        let requestedID = event.id
        let matches = try modelContext.fetch(FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count <= 1 else { throw DurableCalendarError.duplicateLocalRecord }
        let item: CalendarEvent
        if let existing = matches.first {
            item = existing
        } else {
            item = CalendarEvent(id: event.id)
            modelContext.insert(item)
        }
        item.title = event.title
        item.eventDescription = event.description
        item.startTime = startTime
        item.endTime = event.endTime.flatMap(ISODateParser.parse) ?? startTime
        item.allDay = event.allDay
        item.recurrenceRule = event.recurrenceRule
        item.location = event.location
        item.familyMemberIds = familyMemberIDs
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.createdBy = event.createdBy
        item.deletedAt = nil
        item.assignedTo = event.assignedTo
    }

    private static func markCalendarEventDeleted(
        _ event: CalendarEventDTO,
        in modelContext: ModelContext
    ) throws {
        try upsertCalendarEvent(event, in: modelContext)
        let requestedID = event.id
        let matches = try modelContext.fetch(FetchDescriptor<CalendarEvent>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count == 1, let item = matches.first else {
            throw DurableCalendarError.invalidLocalRecord
        }
        let now = Date()
        item.deletedAt = now
        item.updatedAt = now
    }

    private func loadLocalCalendarEvents() {
        guard let modelContext else { return }
        do {
            let rows = try modelContext.fetch(FetchDescriptor<CalendarEvent>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.startTime, order: .forward)]
            ))
            guard !rows.isEmpty else { return }
            let existingByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
            events = rows.map { calendarDTO($0, preserving: existingByID[$0.id]) }
        } catch {
            errorMessage = "Saved events could not be loaded from this device.".localized
        }
    }

    private func mergePendingCalendarEvents(
        with remote: [CalendarEventDTO]
    ) -> [CalendarEventDTO] {
        guard let modelContext else { return remote }
        do {
            let tableName = "calendar_events"
            let synced = OfflineStatus.synced
            let actions = try modelContext.fetch(FetchDescriptor<OfflineAction>(
                predicate: #Predicate {
                    $0.tableName == tableName && $0.status != synced
                },
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            ))
            guard !actions.isEmpty else { return remote }
            let ids = Array(Set(actions.map(\.recordId)))
            let rows = try modelContext.fetch(FetchDescriptor<CalendarEvent>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
            let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            var merged = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
            let previous = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
            for id in ids {
                guard let latest = actions.last(where: { $0.recordId == id }) else { continue }
                if latest.operation == .delete {
                    merged[id] = nil
                } else if let row = rowsByID[id], row.deletedAt == nil {
                    merged[id] = calendarDTO(
                        row,
                        preserving: previous[id] ?? merged[id]
                    )
                }
            }
            return Array(merged.values).sorted { $0.startTime < $1.startTime }
        } catch {
            return remote
        }
    }

    private func calendarDTO(
        _ event: CalendarEvent,
        preserving original: CalendarEventDTO?
    ) -> CalendarEventDTO {
        let memberIDs: [String]?
        // This is a best-effort projection of legacy local JSON. Corruption
        // retains the last server representation rather than erasing assignees.
        if let json = event.familyMemberIds,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            memberIDs = decoded.isEmpty ? nil : decoded
        } else {
            memberIDs = original?.familyMemberIds
        }
        var value = CalendarEventDTO(
            id: event.id,
            seriesId: original?.seriesId,
            isGeneratedOccurrence: original?.isGeneratedOccurrence,
            title: event.title,
            description: event.eventDescription,
            startTime: ISODateParser.stringNoFractional(from: event.startTime),
            endTime: event.endTime == event.startTime
                ? nil : ISODateParser.stringNoFractional(from: event.endTime),
            allDay: event.allDay,
            recurrenceRule: event.recurrenceRule,
            location: event.location,
            familyMemberIds: memberIDs,
            affectedMemberIds: original?.affectedMemberIds,
            createdAt: ISODateParser.stringNoFractional(from: event.createdAt),
            updatedAt: ISODateParser.stringNoFractional(from: event.updatedAt),
            createdBy: event.createdBy,
            assignedTo: event.assignedTo,
            eventType: original?.eventType,
            calendarSourceId: original?.calendarSourceId,
            sourceName: original?.sourceName,
            sourceColor: original?.sourceColor,
            rugbyVenue: original?.rugbyVenue,
            rugbyVenueOverridden: original?.rugbyVenueOverridden,
            readOnly: original?.readOnly,
            overriddenEventId: original?.overriddenEventId,
            sourceDocumentId: original?.sourceDocumentId,
            sourceDocument: original?.sourceDocument,
            attachments: original?.attachments ?? [],
            managedSource: original?.managedSource
        )
        value.sourceDocumentId = original?.sourceDocumentId
        return value
    }

    func completePlannerTask(_ id: String) async {
        do {
            let _: TaskDTO = try await apiClient.patch("/tasks/\(id)/complete", body: EmptyBody())
            plannerTasks.removeAll { $0.id == id }
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to complete task.".localized
        }
    }

    /// Creates a holiday date (day off / INSET day).
    func createHolidayDate(personId: String, date: Date, endDate: Date? = nil, label: String? = nil) async {
        let dates = Self.holidayDates(from: date, through: endDate)

        struct HolidayCreateBody: Encodable {
            let person_id: String
            let date: String
            let label: String?
        }

        for d in dates {
            let body = HolidayCreateBody(
                person_id: personId,
                date: Self.dateOnlyFormatter.string(from: d),
                label: label
            )
            do {
                let _: HolidayDateDTO = try await apiClient.post("/routines/holidays", body: body)
            } catch {
                errorMessage = "Failed to create holiday date.".localized
            }
        }

        // Reload year data
        await loadYearData()
    }

    /// Inclusive, monotonic day expansion. Calendar arithmetic can return nil
    /// for unusual calendar/range combinations; returning the dates accumulated
    /// so far is safer than terminating the app midway through a holiday form.
    static func holidayDates(
        from startDate: Date,
        through optionalEndDate: Date?,
        calendar: Calendar = .current
    ) -> [Date] {
        guard let endDate = optionalEndDate, endDate > startDate else {
            return [startDate]
        }
        var dates = [startDate]
        var current = startDate
        while current < endDate {
            guard let next = calendar.date(byAdding: .day, value: 1, to: current),
                  next > current else {
                break
            }
            current = next
            if current <= endDate { dates.append(current) }
        }
        return dates
    }

    /// Deletes a holiday date (day off / INSET day).
    func deleteHolidayDate(_ holidayId: String) async {
        do {
            try await apiClient.delete("/routines/holidays/\(holidayId)")
            await loadYearData()
        } catch {
            errorMessage = "Failed to delete day off.".localized
        }
    }

    func prepareNewEvent(on date: Date) {
        resetForm()
        formStartTime = date
        formEndTime = date.addingTimeInterval(15 * 60)
        formAllDayEndDate = date
    }

    func beginEditing(
        _ event: CalendarEventDTO,
        recurrenceScope: CalendarRecurrenceMutationScope? = nil,
        calendar: Calendar = .current
    ) {
        resetForm()
        editingEvent = event
        editingRecurrenceScope = recurrenceScope
        formTitle = event.title
        formDescription = event.description ?? ""
        formLocation = event.location ?? ""
        formAllDay = event.allDay
        formAttachments = attachmentInputs(for: event)
        formAttachmentDocuments = attachmentDocuments(for: event)
        syncLegacyPrimaryAttachment()

        let parsedStart = eventBoundary(
            event.startTime,
            allDay: event.allDay,
            calendar: calendar
        ) ?? selectedDate
        formStartTime = parsedStart
        formAllDayEndDate = parsedStart

        if event.allDay {
            if let rawEnd = event.endTime,
               let exclusiveEnd = eventBoundary(
                   rawEnd,
                   allDay: true,
                   calendar: calendar
               ),
               let finalDay = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd),
               finalDay > parsedStart {
                formAllDayIsMultiDay = true
                formAllDayEndDate = finalDay
            }
        } else if let rawEnd = event.endTime,
                  let parsedEnd = eventBoundary(
                      rawEnd,
                      allDay: false,
                      calendar: calendar
                  ),
                  parsedEnd > parsedStart {
            formEndTime = parsedEnd
            let duration = parsedEnd.timeIntervalSince(parsedStart)
            if abs(duration - 15 * 60) < 1 {
                formDurationOption = .fifteenMinutes
            } else if abs(duration - 30 * 60) < 1 {
                formDurationOption = .thirtyMinutes
            } else if abs(duration - 60 * 60) < 1 {
                formDurationOption = .oneHour
            } else {
                formDurationOption = .custom
            }
        } else {
            formDurationOption = .none
            formEndTime = parsedStart.addingTimeInterval(15 * 60)
        }

        let participants = participantIDs(for: event)
        formWholeFamily = participants.isEmpty
        formParticipantIDs = participants
        formAffectedMemberIDs = Set(event.affectedMemberIds ?? [])
        switch event.recurrenceRule?.uppercased() {
        case let rule? where rule.contains("FREQ=DAILY"):
            formRecurrence = "daily"
        case let rule? where rule.contains("FREQ=WEEKLY"):
            formRecurrence = "weekly"
        case let rule? where rule.contains("FREQ=MONTHLY"):
            formRecurrence = "monthly"
        case let rule? where rule.contains("FREQ=YEARLY"):
            formRecurrence = "yearly"
        default:
            formRecurrence = "never"
        }
        formTimingWasEdited = false
        formRecurrenceWasEdited = false
        formPeopleWereEdited = false
        editingInitialTiming = currentFormTiming()
        editingInitialRecurrence = formRecurrence
        editingInitialWholeFamily = formWholeFamily
        editingInitialParticipantIDs = formParticipantIDs
        editingInitialAffectedMemberIDs = formAffectedMemberIDs
        editingInitialTitle = formTitle.trimmingCharacters(in: .whitespaces)
        let initialDescription = formDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        editingInitialDescription = initialDescription.isEmpty ? nil : initialDescription
        let initialLocation = formLocation
            .trimmingCharacters(in: .whitespacesAndNewlines)
        editingInitialLocation = initialLocation.isEmpty ? nil : initialLocation
        editingInitialSourceDocumentId = event.sourceDocumentId
        editingInitialAttachments = formAttachments
    }

    /// Resets all form fields to their default values.
    func resetForm() {
        let now = Date()
        formTitle = ""
        formStartTime = now
        formEndTime = now.addingTimeInterval(15 * 60)
        formAllDay = true
        formDurationOption = .fifteenMinutes
        formAllDayIsMultiDay = false
        formAllDayEndDate = now
        formLocation = ""
        formDescription = ""
        formWholeFamily = true
        formParticipantIDs = []
        formAffectedMemberIDs = []
        formRecurrence = "never"
        formSourceDocumentId = nil
        formSourceDocument = nil
        formAttachments = []
        formAttachmentDocuments = [:]
        formTimingWasEdited = false
        formRecurrenceWasEdited = false
        formPeopleWereEdited = false
        editingInitialTiming = nil
        editingInitialRecurrence = "never"
        editingInitialWholeFamily = true
        editingInitialParticipantIDs = []
        editingInitialAffectedMemberIDs = []
        editingInitialTitle = ""
        editingInitialDescription = nil
        editingInitialLocation = nil
        editingInitialSourceDocumentId = nil
        editingInitialAttachments = []
        pendingCreateRequest = nil
        editingEvent = nil
        editingRecurrenceScope = nil
    }

    // MARK: - Helpers

    private func eventMatchesColumn(
        _ event: CalendarEventDTO,
        columnId: String
    ) -> Bool {
        guard let column = columns.first(where: { $0.id == columnId }) else {
            return true
        }

        switch column.kind {
        case .viewAll:
            return true
        case .person(let id):
            return participantIDs(for: event).contains(id)
                || (event.affectedMemberIds ?? []).contains(id)
        case .kids:
            if let childId = selectedChildFilterId {
                return participantIDs(for: event).contains(childId)
            }
            return !participantIDs(for: event).isDisjoint(with: childIds)
        case .everyone:
            return participantIDs(for: event).isEmpty
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
                  let day = Int(parts[2]) else {
                return nil
            }

            // API all-day values are Gregorian civil dates. Interpret them at midnight
            // in the calendar's timezone rather than as UTC instants.
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = calendar.timeZone
            var components = DateComponents()
            components.calendar = gregorian
            components.timeZone = gregorian.timeZone
            components.year = year
            components.month = month
            components.day = day

            guard let parsed = gregorian.date(from: components) else { return nil }
            let verified = gregorian.dateComponents([.year, .month, .day], from: parsed)
            guard verified.year == year,
                  verified.month == month,
                  verified.day == day else {
                return nil
            }
            return parsed
        }

        return parseISO8601(value)
    }

    private func shortTime(_ date: Date, calendar: Calendar) -> String {
        if calendar.timeZone.identifier == TimeZone.current.identifier {
            return Self.shortTimeFormatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    /// Parses an ISO 8601 date string, trying fractional seconds first.
    func parseISO8601(_ string: String) -> Date? {
        ISODateParser.parse(string)
    }

    /// Formats an ISO 8601 date string into a short time display (e.g., "9:30 AM").
    func formattedTime(_ isoString: String) -> String {
        guard let date = parseISO8601(isoString) else { return isoString }
        return Self.shortTimeFormatter.string(from: date)
    }

    /// Formats a time range from two ISO 8601 strings (e.g., "9:30 AM - 10:30 AM").
    func formattedTimeRange(start: String, end: String?) -> String {
        guard let end else { return formattedTime(start) }
        if let startDate = parseISO8601(start), let endDate = parseISO8601(end) {
            return "\(Self.shortTimeFormatter.string(from: startDate)) - \(Self.shortTimeFormatter.string(from: endDate))"
        }
        return "\(start) - \(end)"
    }

    func tasksForDate(_ date: Date) -> [TaskDTO] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let isToday = calendar.isDateInToday(date)

        return plannerTasks
            .filter { task in
                guard let due = task.dueDate.flatMap(ISODateParser.parse) else {
                    return isToday
                }
                return isToday ? due < dayEnd : (due >= dayStart && due < dayEnd)
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return ($0.dueDate ?? "") < ($1.dueDate ?? "")
            }
    }

    private func recurrenceRule(for date: Date) -> String? {
        switch formRecurrence {
        case "daily":
            return "FREQ=DAILY"
        case "weekly":
            let symbols = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let weekday = Calendar.current.component(.weekday, from: date)
            return "FREQ=WEEKLY;BYDAY=\(symbols[max(0, min(weekday - 1, 6))])"
        case "monthly":
            return "FREQ=MONTHLY"
        case "yearly":
            return "FREQ=YEARLY"
        default:
            return nil
        }
    }
}
