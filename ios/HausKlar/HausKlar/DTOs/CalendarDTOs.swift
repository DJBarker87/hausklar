import Foundation
import SwiftUI

// MARK: - Calendar DTOs

enum CalendarEventAttachmentRole: String, Codable, CaseIterable, Identifiable {
    case ticket
    case booking
    case schoolLetter = "school_letter"
    case insurance
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ticket: "Ticket"
        case .booking: "Booking"
        case .schoolLetter: "School letter"
        case .insurance: "Insurance"
        case .other: "Other"
        }
    }
}

struct CalendarEventAttachmentInput: Codable, Equatable, Identifiable {
    let documentId: String
    var role: CalendarEventAttachmentRole
    var id: String { documentId }
}

struct CalendarEventAttachmentDTO: Codable, Equatable, Identifiable {
    let relationId: String
    let role: CalendarEventAttachmentRole
    let position: Int
    let id: String
    let title: String
    let originalFilename: String
    let mediaType: String
    let fileSize: Int
    let downloadUrl: String

    var document: SourceDocumentDTO {
        SourceDocumentDTO(
            id: id,
            title: title,
            originalFilename: originalFilename,
            mediaType: mediaType,
            fileSize: fileSize,
            downloadUrl: downloadUrl
        )
    }
}

struct ManagedSourceDTO: Codable, Equatable {
    let kind: String
    let sourceId: String
    let deepLink: String
    let label: String

    var financeWebURL: URL? {
        guard kind.hasPrefix("finance_"),
              let router = FinanceWebRouter.configured() else { return nil }
        return router.url(relativeFinanceDeepLink: deepLink)
    }
}

struct FinanceProjectionPreferenceDTO: Codable, Equatable {
    let showMoney: Bool
    let showDeliveries: Bool
}

/// Represents a calendar event as returned by the API.
struct CalendarEventDTO: Codable, Identifiable {
    let id: String
    var seriesId: String? = nil
    var isGeneratedOccurrence: Bool? = nil
    let title: String
    let description: String?
    let startTime: String
    let endTime: String?
    let allDay: Bool
    let recurrenceRule: String?
    let location: String?
    let familyMemberIds: [String]?
    var affectedMemberIds: [String]? = nil
    let createdAt: String
    let updatedAt: String
    let createdBy: String?
    let assignedTo: String?
    var eventType: String? = nil
    var calendarSourceId: String? = nil
    var sourceName: String? = nil
    var sourceColor: String? = nil
    var rugbyVenue: String? = nil
    var rugbyVenueOverridden: Bool? = nil
    var readOnly: Bool? = nil
    var overriddenEventId: String? = nil
    var sourceDocumentId: String? = nil
    var sourceDocument: SourceDocumentDTO? = nil
    var attachments: [CalendarEventAttachmentDTO] = []
    var managedSource: ManagedSourceDTO? = nil

    var isCycleProjection: Bool {
        eventType?.hasPrefix("cycle_") == true
    }

    var isFitnessProjection: Bool {
        eventType?.hasPrefix("fitness_") == true
    }

    var isFacilityProjection: Bool {
        eventType?.hasPrefix("facility_") == true
    }

    var isFinanceManaged: Bool {
        managedSource != nil && eventType?.hasPrefix("finance_") == true
    }

    var isSchoolClubProjection: Bool {
        eventType == "school_club" || eventType == "school_club_cancelled"
    }

    var isCancelledSchoolClub: Bool {
        eventType == "school_club_cancelled"
    }

    var isToastProjection: Bool {
        eventType == "toast_club" || eventType == "toast_club_conflict"
    }

    var isSchoolMilestone: Bool {
        eventType == "school_milestone"
    }

    var financeCategoryLabel: String? {
        guard isFinanceManaged else { return nil }
        return eventType == "finance_delivery" ? "Deliveries" : "Money"
    }
}

extension CalendarEventDTO {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
        isGeneratedOccurrence = try container.decodeIfPresent(
            Bool.self,
            forKey: .isGeneratedOccurrence
        )
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        startTime = try container.decode(String.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(String.self, forKey: .endTime)
        allDay = try container.decode(Bool.self, forKey: .allDay)
        recurrenceRule = try container.decodeIfPresent(String.self, forKey: .recurrenceRule)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        familyMemberIds = try container.decodeIfPresent([String].self, forKey: .familyMemberIds)
        affectedMemberIds = try container.decodeIfPresent([String].self, forKey: .affectedMemberIds)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        assignedTo = try container.decodeIfPresent(String.self, forKey: .assignedTo)
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType)
        calendarSourceId = try container.decodeIfPresent(String.self, forKey: .calendarSourceId)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        sourceColor = try container.decodeIfPresent(String.self, forKey: .sourceColor)
        rugbyVenue = try container.decodeIfPresent(String.self, forKey: .rugbyVenue)
        rugbyVenueOverridden = try container.decodeIfPresent(
            Bool.self,
            forKey: .rugbyVenueOverridden
        )
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly)
        overriddenEventId = try container.decodeIfPresent(String.self, forKey: .overriddenEventId)
        sourceDocumentId = try container.decodeIfPresent(String.self, forKey: .sourceDocumentId)
        sourceDocument = try container.decodeIfPresent(SourceDocumentDTO.self, forKey: .sourceDocument)
        attachments = try container.decodeIfPresent(
            [CalendarEventAttachmentDTO].self,
            forKey: .attachments
        ) ?? []
        managedSource = try container.decodeIfPresent(ManagedSourceDTO.self, forKey: .managedSource)
    }
}

enum CalendarRecurrenceMutationScope: String, Codable, CaseIterable, Identifiable {
    case onlyThis = "only_this"
    case thisAndLater = "this_and_later"
    case entireSeries = "entire_series"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onlyThis: "Only this event"
        case .thisAndLater: "This and later events"
        case .entireSeries: "Every event in series"
        }
    }
}

struct CyclePeriodStartDTO: Codable, Identifiable, Equatable {
    let id: String
    let startedOn: String
    let createdAt: String
    let updatedAt: String
    var revision: Int? = nil
}

struct CycleProfileDTO: Decodable, Identifiable, Equatable {
    let id: String
    let ownerUserId: String
    let ownerName: String
    let isOwner: Bool
    let cycleLengthDays: Int
    let showPeriodStarts: Bool
    let showPredictedPeriod: Bool
    let showEstimatedOvulation: Bool
    /// Sharing consent is deliberately independent for each projection. The
    /// legacy all-or-nothing flag is decoded only for migration visibility and
    /// never silently enables one of these permissions.
    let sharePeriodStartsWithAdults: Bool
    let sharePredictedPeriodWithAdults: Bool
    let shareEstimatedOvulationWithAdults: Bool
    let latestPeriodStart: String?
    let predictedNextPeriod: String?
    let estimatedOvulation: String?
    let periodStarts: [CyclePeriodStartDTO]
    let revision: Int
    let createdAt: String
    let updatedAt: String

    /// Kept so an old cached profile can still be decoded and shown while the
    /// new Fitness cache is first populated. New writes never use this value.
    let legacyShareWithAdults: Bool

    init(
        id: String,
        ownerUserId: String,
        ownerName: String,
        isOwner: Bool,
        cycleLengthDays: Int,
        showPeriodStarts: Bool,
        showPredictedPeriod: Bool,
        showEstimatedOvulation: Bool,
        sharePeriodStartsWithAdults: Bool = false,
        sharePredictedPeriodWithAdults: Bool = false,
        shareEstimatedOvulationWithAdults: Bool = false,
        latestPeriodStart: String?,
        predictedNextPeriod: String?,
        estimatedOvulation: String?,
        periodStarts: [CyclePeriodStartDTO],
        revision: Int = 0,
        createdAt: String,
        updatedAt: String,
        legacyShareWithAdults: Bool = false
    ) {
        self.id=id; self.ownerUserId=ownerUserId; self.ownerName=ownerName
        self.isOwner=isOwner; self.cycleLengthDays=cycleLengthDays
        self.showPeriodStarts=showPeriodStarts
        self.showPredictedPeriod=showPredictedPeriod
        self.showEstimatedOvulation=showEstimatedOvulation
        self.sharePeriodStartsWithAdults=sharePeriodStartsWithAdults
        self.sharePredictedPeriodWithAdults=sharePredictedPeriodWithAdults
        self.shareEstimatedOvulationWithAdults=shareEstimatedOvulationWithAdults
        self.latestPeriodStart=latestPeriodStart
        self.predictedNextPeriod=predictedNextPeriod
        self.estimatedOvulation=estimatedOvulation
        self.periodStarts=periodStarts; self.revision=revision
        self.createdAt=createdAt; self.updatedAt=updatedAt
        self.legacyShareWithAdults=legacyShareWithAdults
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerUserId, ownerName, isOwner, cycleLengthDays
        case showPeriodStarts, showPredictedPeriod, showEstimatedOvulation
        case sharePeriodStartsWithAdults, sharePredictedPeriodWithAdults
        case shareEstimatedOvulationWithAdults, shareWithAdults
        case latestPeriodStart, predictedNextPeriod, estimatedOvulation
        case periodStarts, revision, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values=try decoder.container(keyedBy: CodingKeys.self)
        id=try values.decode(String.self,forKey: .id)
        ownerUserId=try values.decode(String.self,forKey: .ownerUserId)
        ownerName=try values.decode(String.self,forKey: .ownerName)
        isOwner=try values.decode(Bool.self,forKey: .isOwner)
        cycleLengthDays=try values.decode(Int.self,forKey: .cycleLengthDays)
        showPeriodStarts=try values.decodeIfPresent(Bool.self,forKey: .showPeriodStarts) ?? true
        showPredictedPeriod=try values.decodeIfPresent(Bool.self,forKey: .showPredictedPeriod) ?? true
        showEstimatedOvulation=try values.decodeIfPresent(Bool.self,forKey: .showEstimatedOvulation) ?? true
        sharePeriodStartsWithAdults=try values.decodeIfPresent(
            Bool.self,forKey: .sharePeriodStartsWithAdults
        ) ?? false
        sharePredictedPeriodWithAdults=try values.decodeIfPresent(
            Bool.self,forKey: .sharePredictedPeriodWithAdults
        ) ?? false
        shareEstimatedOvulationWithAdults=try values.decodeIfPresent(
            Bool.self,forKey: .shareEstimatedOvulationWithAdults
        ) ?? false
        legacyShareWithAdults=try values.decodeIfPresent(Bool.self,forKey: .shareWithAdults) ?? false
        latestPeriodStart=try values.decodeIfPresent(String.self,forKey: .latestPeriodStart)
        predictedNextPeriod=try values.decodeIfPresent(String.self,forKey: .predictedNextPeriod)
        estimatedOvulation=try values.decodeIfPresent(String.self,forKey: .estimatedOvulation)
        periodStarts=try values.decodeIfPresent([CyclePeriodStartDTO].self,forKey: .periodStarts) ?? []
        revision=try values.decodeIfPresent(Int.self,forKey: .revision) ?? 0
        createdAt=try values.decodeIfPresent(String.self,forKey: .createdAt) ?? ""
        updatedAt=try values.decodeIfPresent(String.self,forKey: .updatedAt) ?? createdAt
    }
}

struct UpdateCycleSettingsRequest: Encodable, Equatable {
    let id: String
    let cycleLengthDays: Int
    let showPeriodStarts: Bool
    let showPredictedPeriod: Bool
    let showEstimatedOvulation: Bool
    let sharePeriodStartsWithAdults: Bool
    let sharePredictedPeriodWithAdults: Bool
    let shareEstimatedOvulationWithAdults: Bool

    init(
        id: String = UUID().uuidString,
        cycleLengthDays: Int,
        showPeriodStarts: Bool,
        showPredictedPeriod: Bool,
        showEstimatedOvulation: Bool,
        sharePeriodStartsWithAdults: Bool = false,
        sharePredictedPeriodWithAdults: Bool = false,
        shareEstimatedOvulationWithAdults: Bool = false
    ) {
        self.id = id
        self.cycleLengthDays = cycleLengthDays
        self.showPeriodStarts = showPeriodStarts
        self.showPredictedPeriod = showPredictedPeriod
        self.showEstimatedOvulation = showEstimatedOvulation
        self.sharePeriodStartsWithAdults=sharePeriodStartsWithAdults
        self.sharePredictedPeriodWithAdults=sharePredictedPeriodWithAdults
        self.shareEstimatedOvulationWithAdults=shareEstimatedOvulationWithAdults
    }
}

struct CreatePeriodStartRequest: Encodable, Equatable {
    let id: String
    let startedOn: String

    init(id: String = UUID().uuidString, startedOn: String) {
        self.id = id
        self.startedOn = startedOn
    }

}

struct CalendarSourceDTO: Codable, Identifiable {
    let id: String
    let name: String
    let hostname: String
    let assignedTo: String?
    let color: String
    let enabled: Bool
    let lastSyncedAt: String?
    let lastSuccessAt: String?
    let lastError: String?
    let createdAt: String
    let updatedAt: String
}

struct CalendarFeedStatusDTO: Codable {
    let configured: Bool
    let tokenPrefix: String?
    let feedUrl: String?
}

struct CalendarFeedCreatedDTO: Codable {
    let configured: Bool
    let tokenPrefix: String?
    let feedUrl: String?
    let token: String
}

struct CreateCalendarSourceRequest: Encodable {
    let name: String
    let url: String
    let assignedTo: String?
    let color: String
}

struct CalendarSourceValidationDTO: Codable, Equatable {
    let valid: Bool
    let hostname: String
    let eventCount: Int
}

struct CalendarSourceSyncDTO: Codable {
    let sourceId: String
    let events: Int
    let changed: Int
    let removed: Int
    let unchanged: Bool
}

struct SchoolRugbyTeamDTO: Codable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct SchoolRugbyTeamListDTO: Codable, Equatable {
    let season: String
    let teams: [SchoolRugbyTeamDTO]
}

struct SchoolRugbySettingsDTO: Codable, Equatable {
    let configured: Bool
    let sourceId: String?
    let teamId: String?
    let teamName: String?
    let season: String?
    let ownerUserId: String?
    let ownerName: String?
    let affectedUserIds: [String]
    let affectedNames: [String]
    let fixtureCount: Int
    let lastSyncedAt: String?
    let lastSuccessAt: String?
    let lastError: String?

    static let unconfigured = SchoolRugbySettingsDTO(
        configured: false,
        sourceId: nil,
        teamId: nil,
        teamName: nil,
        season: nil,
        ownerUserId: nil,
        ownerName: nil,
        affectedUserIds: [],
        affectedNames: [],
        fixtureCount: 0,
        lastSyncedAt: nil,
        lastSuccessAt: nil,
        lastError: nil
    )
}

struct SchoolRugbySettingsRequest: Encodable, Equatable {
    let teamId: String
}

struct SchoolRugbyVenueRequest: Encodable, Equatable {
    let venue: String
}

struct ReminderPreferencesDTO: Codable, Equatable {
    var eventRemindersEnabled: Bool
    var eventMinutesBefore: Int
    var taskRemindersEnabled: Bool
    var morningSummaryEnabled: Bool
    var morningSummaryTime: String
    var eveningSummaryEnabled: Bool
    var eveningSummaryTime: String
    var quietStart: String
    var quietEnd: String
    var privacyMode: Bool
}

struct ReminderPreviewDTO: Codable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let detail: String
    let scheduledFor: String
    let url: String
}

struct APNSDeviceRegistrationRequest: Encodable, Equatable {
    let deviceToken: String
    let environment: String
    let appVersion: String?
}

struct APNSDeviceStatusDTO: Decodable, Equatable {
    let configured: Bool
    let registered: Bool
    let tokenDigest: String?
}

struct NotificationTestResultDTO: Decodable, Equatable {
    let delivered: Int
}

/// Request body for creating a new calendar event.
struct CreateCalendarEventRequest: Encodable, Equatable {
    let id: String
    let title: String
    let description: String?
    let startTime: String
    let endTime: String?
    let allDay: Bool
    let recurrenceRule: String?
    let location: String?
    let familyMemberIds: [String]?
    let affectedMemberIds: [String]?
    let assignedTo: String?
    var sourceDocumentId: String? = nil
    var attachments: [CalendarEventAttachmentInput]? = nil
}

enum CalendarEventUpdateField: Hashable {
    case title
    case description
    case startTime
    case endTime
    case allDay
    case recurrenceRule
    case location
    case familyMemberIds
    case affectedMemberIds
    case assignedTo
    case sourceDocumentId
    case attachments
}

/// Sparse request body for editing an existing calendar event. `includedFields`
/// distinguishes an untouched value from an explicit JSON null, which is
/// required for clearing optional fields without overwriting unrelated data.
struct UpdateCalendarEventRequest: Encodable, Equatable {
    let title: String?
    let description: String?
    let startTime: String?
    let endTime: String?
    let allDay: Bool?
    let recurrenceRule: String?
    let location: String?
    let familyMemberIds: [String]?
    let affectedMemberIds: [String]?
    let assignedTo: String?
    var sourceDocumentId: String? = nil
    var attachments: [CalendarEventAttachmentInput]? = nil
    let clientId: String?
    let clientTimestamp: String?
    let includedFields: Set<CalendarEventUpdateField>

    var isEmpty: Bool { includedFields.isEmpty }

    enum CodingKeys: String, CodingKey {
        case title, description, startTime, endTime, allDay, recurrenceRule
        case location, familyMemberIds, affectedMemberIds, assignedTo
        case sourceDocumentId, attachments
        case clientId, clientTimestamp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if includedFields.contains(.title) {
            try container.encode(title, forKey: .title)
        }
        if includedFields.contains(.description) {
            try container.encode(description, forKey: .description)
        }
        if includedFields.contains(.startTime) {
            try container.encode(startTime, forKey: .startTime)
        }
        if includedFields.contains(.endTime) {
            try container.encode(endTime, forKey: .endTime)
        }
        if includedFields.contains(.allDay) {
            try container.encode(allDay, forKey: .allDay)
        }
        if includedFields.contains(.recurrenceRule) {
            try container.encode(recurrenceRule, forKey: .recurrenceRule)
        }
        if includedFields.contains(.location) {
            try container.encode(location, forKey: .location)
        }
        if includedFields.contains(.familyMemberIds) {
            try container.encode(familyMemberIds, forKey: .familyMemberIds)
        }
        if includedFields.contains(.affectedMemberIds) {
            try container.encode(affectedMemberIds, forKey: .affectedMemberIds)
        }
        if includedFields.contains(.assignedTo) {
            try container.encode(assignedTo, forKey: .assignedTo)
        }
        if includedFields.contains(.sourceDocumentId) {
            try container.encode(sourceDocumentId, forKey: .sourceDocumentId)
        }
        if includedFields.contains(.attachments) {
            try container.encode(attachments ?? [], forKey: .attachments)
        }
        try container.encodeIfPresent(clientId, forKey: .clientId)
        try container.encodeIfPresent(clientTimestamp, forKey: .clientTimestamp)
    }

    /// Payload accepted by `/sync/push`; metadata is supplied by SyncManager.
    var offlinePayload: [String: Any] {
        var payload: [String: Any] = [:]
        if includedFields.contains(.title) { payload["title"] = title ?? NSNull() }
        if includedFields.contains(.description) { payload["description"] = description ?? NSNull() }
        if includedFields.contains(.startTime) { payload["start_time"] = startTime ?? NSNull() }
        if includedFields.contains(.endTime) { payload["end_time"] = endTime ?? NSNull() }
        if includedFields.contains(.allDay) { payload["all_day"] = allDay ?? NSNull() }
        if includedFields.contains(.recurrenceRule) { payload["recurrence_rule"] = recurrenceRule ?? NSNull() }
        if includedFields.contains(.location) { payload["location"] = location ?? NSNull() }
        if includedFields.contains(.familyMemberIds) { payload["family_member_ids"] = familyMemberIds ?? NSNull() }
        if includedFields.contains(.affectedMemberIds) { payload["affected_member_ids"] = affectedMemberIds ?? NSNull() }
        if includedFields.contains(.assignedTo) { payload["assigned_to"] = assignedTo ?? NSNull() }
        if includedFields.contains(.sourceDocumentId) { payload["source_document_id"] = sourceDocumentId ?? NSNull() }
        // Many-document relations deliberately remain outside generic offline
        // transport. The legacy primary link above keeps queued edits safe.
        return payload
    }
}

struct UpdateCalendarOccurrenceRequest: Encodable, Equatable {
    let scope: CalendarRecurrenceMutationScope
    let occurrenceStart: String
    let updates: UpdateCalendarEventRequest
}

struct DeleteCalendarOccurrenceRequest: Encodable, Equatable {
    let scope: CalendarRecurrenceMutationScope
    let occurrenceStart: String
    let clientId: String?
    let clientTimestamp: String?
}

struct HolidayDateDTO: Codable, Identifiable, Equatable {
    let id: String
    let personId: String
    let date: String
    let label: String?
    let createdAt: String
    let updatedAt: String
}

struct TermStatusEntryDTO: Codable {
    let personId: String
    let inTerm: Bool
}

struct TermStatusResponseDTO: Codable {
    let statuses: [TermStatusEntryDTO]
    let allSame: Bool
}

// MARK: - Calendar Supporting Types

enum CalendarViewMode: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"

    var icon: String {
        switch self {
        case .day: return "list.bullet"
        case .week: return "calendar.day.timeline.left"
        case .month: return "calendar"
        case .year: return "calendar.badge.clock"
        }
    }
}

enum CalendarEventDurationOption: String, CaseIterable, Identifiable {
    case none
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case custom

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .none, .custom: return nil
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        }
    }

    var label: String {
        switch self {
        case .none: return "No duration"
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 hour"
        case .custom: return "Custom end"
        }
    }
}

struct ColumnDef: Identifiable, Hashable {
    enum Kind: Hashable {
        case viewAll
        case person(id: String)
        case kids
        case everyone
    }
    let kind: Kind
    let label: String
    let color: Color

    var id: String {
        switch kind {
        case .viewAll: return "__all__"
        case .person(let id): return id
        case .kids: return "__kids__"
        case .everyone: return "__everyone__"
        }
    }
}
