import Foundation

enum CommitmentKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case school
    case invitation
    case outing
    case childcare
    case appointment
    case travel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .school: "School message".localized
        case .invitation: "Invitation".localized
        case .outing: "Family outing".localized
        case .childcare: "Childcare gap".localized
        case .appointment: "Appointment".localized
        case .travel: "Travel booking".localized
        }
    }

    var detail: String {
        switch self {
        case .school: "Dates, actions and things to bring".localized
        case .invitation: "Date, RSVP and event details".localized
        case .outing: "Find a time that works before booking".localized
        case .childcare: "Find uncovered holiday days".localized
        case .appointment: "Keep the booking and what it needs".localized
        case .travel: "Keep journeys and stays together".localized
        }
    }

    var symbol: String {
        switch self {
        case .school: "graduationcap.fill"
        case .invitation: "party.popper.fill"
        case .outing: "map.fill"
        case .childcare: "figure.and.child.holdinghands"
        case .appointment: "stethoscope"
        case .travel: "airplane"
        }
    }
}

enum CommitmentVisibility: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case family
    case owner

    var id: String { rawValue }
    var title: String { self == .family ? "Family".localized : "Just me".localized }
}

enum CommitmentStatus: String, Codable, Hashable, Sendable {
    case draft
    case actionRequired = "action_required"
    case ready
    case confirmed
    case declined

    var isOpen: Bool { self == .draft || self == .actionRequired || self == .ready }
}

enum CommitmentSourceKind: String, Codable, Hashable, Sendable {
    case document, email, share, manual, provider
}

struct CommitmentSource: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var kind: CommitmentSourceKind
    var documentId: String?
    var label: String?
    var providerReference: String?
    var sourceUrl: String?
    var observedAt: String?
}

struct CommitmentEventDraft: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String?
    var startTime: String
    var endTime: String?
    var allDay: Bool
    var location: String?
    var personIds: [String]
    var affectedAdultIds: [String]
    var assignedTo: String?
    var eventType: String
    var documentIds: [String]
}

struct CommitmentTaskDraft: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var title: String
    var description: String?
    var dueDate: String?
    var actionableFrom: String?
    var assignedTo: String?
    var priority: Int
    var documentId: String?
}

struct CommitmentPreparationDraft: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var eventId: String
    var name: String
    var items: [String]
    var leadHours: Int
    var assignedTo: String?
}

enum CommitmentExternalActionKind: String, Codable, CaseIterable, Identifiable, Hashable,
    Sendable
{
    case rsvp, book, register, contact, pay, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rsvp: "RSVP"
        case .book: "Book".localized
        case .register: "Register or check in".localized
        case .contact: "Contact".localized
        case .pay: "Pay".localized
        case .other: "Other".localized
        }
    }
}

enum CommitmentExternalTargetType: String, Codable, CaseIterable, Identifiable, Hashable,
    Sendable
{
    case https, email, phone, manual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .https: "Website".localized
        case .email: "Email".localized
        case .phone: "Phone".localized
        case .manual: "Instructions only".localized
        }
    }
}

struct CommitmentExternalAction: Codable, Equatable, Hashable, Sendable {
    var kind: CommitmentExternalActionKind
    var label: String
    var targetType: CommitmentExternalTargetType
    var target: String
    var dueAt: String?
    var requiresCompletionBeforeConfirm: Bool

    var handoffURL: URL? {
        switch targetType {
        case .https:
            SafeExternalURL.web(target)
        case .email:
            SafeExternalURL.contact("mailto:\(target)")
        case .phone:
            SafeExternalURL.contact("tel:\(target.filter { $0.isNumber || $0 == "+" })")
        case .manual:
            nil
        }
    }

    var completionOutcome: CommitmentActionOutcome {
        switch kind {
        case .book, .register: .booked
        case .rsvp, .contact: .replied
        case .pay: .completed
        case .other: .other
        }
    }
}

struct CommitmentPlan: Codable, Equatable, Hashable, Sendable {
    var events: [CommitmentEventDraft]
    var tasks: [CommitmentTaskDraft]
    var preparations: [CommitmentPreparationDraft]
    var externalAction: CommitmentExternalAction?

    static let empty = Self(events: [], tasks: [], preparations: [], externalAction: nil)
}

enum CommitmentExternalActionStatus: String, Codable, Hashable, Sendable {
    case notRequired = "not_required"
    case pending, completed, declined
}

struct CommitmentResult: Codable, Equatable, Hashable, Sendable {
    let sourceItemId: String
    let resultType: String
    let resultId: String
}

struct CommitmentTemporalUrgency: Equatable, Sendable {
    enum Precision: Equatable, Sendable {
        case dateOnly
        case dateTime
    }

    let date: Date
    let precision: Precision

    func formatted(locale: Locale) -> String {
        if precision == .dateOnly {
            return date.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                    .locale(locale)
            )
        }
        return date.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .hour().minute().locale(locale)
        )
    }
}

struct Commitment: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var kind: CommitmentKind
    var visibility: CommitmentVisibility
    var ownerUserId: String
    var title: String
    var summary: String?
    var status: CommitmentStatus
    var revision: Int
    var sources: [CommitmentSource]
    var plan: CommitmentPlan
    var reviewIssues: [String]
    var externalActionStatus: CommitmentExternalActionStatus
    var externalActionOutcome: String?
    var externalActionCompletedAt: String?
    var groupKey: String?
    var interpretationProcessor: String?
    var supersedesId: String?
    var changeSummary: [String]
    var confirmedAt: String?
    var declinedAt: String?
    var results: [CommitmentResult]
    var createdAt: String
    var updatedAt: String
    var createdBy: String?
    var clientId: String?
    var clientTimestamp: String?

    var temporalUrgency: CommitmentTemporalUrgency? {
        let eventValues = plan.events.compactMap { event -> CommitmentTemporalUrgency? in
            guard let value = ISODateParser.parse(event.startTime) else { return nil }
            return CommitmentTemporalUrgency(
                date: value,
                precision: event.allDay || Self.isDateOnly(event.startTime)
                    ? .dateOnly : .dateTime
            )
        }
        let taskValues = plan.tasks.compactMap { task -> CommitmentTemporalUrgency? in
            guard let dueDate = task.dueDate,
                  let value = ISODateParser.parse(dueDate) else { return nil }
            return CommitmentTemporalUrgency(date: value, precision: .dateOnly)
        }
        let actionValues = [plan.externalAction?.dueAt].compactMap { raw -> CommitmentTemporalUrgency? in
            guard let raw, let value = ISODateParser.parse(raw) else { return nil }
            return CommitmentTemporalUrgency(
                date: value,
                precision: Self.isDateOnly(raw) ? .dateOnly : .dateTime
            )
        }
        return (eventValues + taskValues + actionValues).min { $0.date < $1.date }
    }

    var urgency: Date { temporalUrgency?.date ?? .distantFuture }

    var actionBlocksConfirmation: Bool {
        plan.externalAction?.requiresCompletionBeforeConfirm == true
            && externalActionStatus != .completed
    }

    var updateReviewItems: [String] {
        if !changeSummary.isEmpty { return changeSummary }
        return supersedesId == nil
            ? []
            : ["This plan updates an earlier plan.".localized]
    }

    func canConfirm(currentUserId: String?) -> Bool {
        status.isOpen
            && visibility == .family
            && reviewIssues.isEmpty
            && !actionBlocksConfirmation
            && currentUserId != nil
    }

    private static func isDateOnly(_ value: String) -> Bool {
        value.count == 10 && value[value.index(value.startIndex, offsetBy: 4)] == "-"
            && value[value.index(value.startIndex, offsetBy: 7)] == "-"
    }
}

struct CommitmentDocumentOption: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let extractedText: String?
    let status: String
}

struct CommitmentFromSourceRequest: Encodable, Equatable, Sendable {
    let id: String
    let kind: CommitmentKind
    let visibility: CommitmentVisibility
    let text: String?
    let sourceDocumentId: String?
    let sourceLabel: String?
    let providerReference: String?
    let title: String?
    let useHermes: Bool
    let clientNow: String
    let timezone: String
    let supersedesId: String?
    let clientId: String
    let clientTimestamp: String
}

struct CommitmentFromSourceResponse: Decodable, Equatable, Sendable {
    let commitment: Commitment
    let processor: String
    let warning: String?
    let deduplicated: Bool
    let materialChanges: [String]
}

struct CommitmentCreateRequest: Encodable, Equatable, Sendable {
    let id: String
    let kind: CommitmentKind
    let visibility: CommitmentVisibility
    let title: String
    let summary: String?
    let sources: [CommitmentSource]
    let plan: CommitmentPlan
    let groupKey: String?
    let clientId: String
    let clientTimestamp: String
}

struct CommitmentUpdateRequest: Encodable, Equatable, Sendable {
    let expectedRevision: Int
    let visibility: CommitmentVisibility?
    let title: String
    let summary: String?
    let sources: [CommitmentSource]
    let plan: CommitmentPlan
    let groupKey: String?
    let clientId: String
    let clientTimestamp: String

    private enum CodingKeys: String, CodingKey {
        case expectedRevision, visibility, title, summary, sources, plan, groupKey
        case clientId, clientTimestamp
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(expectedRevision, forKey: .expectedRevision)
        try values.encodeIfPresent(visibility, forKey: .visibility)
        try values.encode(title, forKey: .title)
        try values.encode(summary, forKey: .summary)
        try values.encode(sources, forKey: .sources)
        try values.encode(plan, forKey: .plan)
        try values.encode(groupKey, forKey: .groupKey)
        try values.encode(clientId, forKey: .clientId)
        try values.encode(clientTimestamp, forKey: .clientTimestamp)
    }
}

enum CommitmentActionOutcome: String, Codable, Sendable {
    case accepted, booked, replied, completed, other
}

struct CommitmentActionCompleteRequest: Encodable, Equatable, Sendable {
    let expectedRevision: Int
    let completed: Bool
    let outcome: CommitmentActionOutcome
    let clientId: String
    let clientTimestamp: String
}

struct CommitmentConfirmRequest: Encodable, Equatable, Sendable {
    let expectedRevision: Int
    let confirmed: Bool
    let clientId: String
    let clientTimestamp: String
}

struct CommitmentDeclineRequest: Encodable, Equatable, Sendable {
    let expectedRevision: Int
    let reason: String?
    let clientId: String
    let clientTimestamp: String
}

struct CommitmentFreeWindowCandidate: Encodable, Equatable, Sendable {
    let id: String
    let title: String
    let availableStart: String
    let availableEnd: String
    let durationMinutes: Int
    let location: String?
    let bookingUrl: String?
}

struct CommitmentFreeWindowQuery: Encodable, Equatable, Sendable {
    let startTime: String
    let endTime: String
    let personIds: [String]
    let minimumMinutes: Int
    let candidates: [CommitmentFreeWindowCandidate]
    let timezone: String
}

struct CommitmentFreeWindow: Decodable, Equatable, Hashable, Sendable {
    let startTime: String
    let endTime: String
    let durationMinutes: Int
}

struct CommitmentViableOuting: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let candidateId: String
    let title: String
    let proposedStart: String
    let proposedEnd: String
    let location: String?
    let bookingUrl: String?

    var id: String { "\(candidateId)|\(proposedStart)|\(proposedEnd)" }
}

struct CommitmentFreeWindowResponse: Decodable, Equatable, Sendable {
    let windows: [CommitmentFreeWindow]
    let viableOutings: [CommitmentViableOuting]
}

struct CommitmentChildcareGap: Decodable, Identifiable, Equatable, Hashable, Sendable {
    let date: String
    let label: String
    let source: String

    var id: String { date }
}

struct CommitmentMutationMetadata: Equatable, Sendable {
    let id: String
    let timestamp: String
}
