import Foundation

enum UniversalCaptureKind: String, Codable, CaseIterable, Hashable {
    case event
    case task
    case shopping

    var title: String {
        switch self {
        case .event: return "Event".localized
        case .task: return "Task".localized
        case .shopping: return "Shopping item".localized
        }
    }

    var icon: String {
        switch self {
        case .event: return "calendar"
        case .task: return "checkmark.circle"
        case .shopping: return "cart.badge.plus"
        }
    }

    var reviewActionTitle: String {
        switch self {
        case .event: return "Create event".localized
        case .task: return "Create task".localized
        case .shopping: return "Add to shopping".localized
        }
    }
}

enum CaptureDirectAction: String, CaseIterable, Equatable {
    case task
    case event
    case shopping
    case document

    var title: String {
        switch self {
        case .task: return "Task".localized
        case .event: return "Event".localized
        case .shopping: return "Shopping".localized
        case .document: return "Scan".localized
        }
    }

    var icon: String {
        switch self {
        case .task: return "checkmark.circle"
        case .event: return "calendar.badge.plus"
        case .shopping: return "cart.badge.plus"
        case .document: return "doc.viewfinder"
        }
    }

    var proposalKind: UniversalCaptureKind? {
        switch self {
        case .task: return .task
        case .event: return .event
        case .shopping: return .shopping
        case .document: return nil
        }
    }
}

struct UniversalCaptureParseRequest: Encodable {
    let text: String
    let useHermes: Bool
    let clientNow: String
    let timezone: String
}

struct UniversalCaptureResponseDTO: Decodable {
    let proposals: [UniversalCaptureProposalDTO]
    let processor: String
    let warning: String?
}

struct UniversalCaptureProposalDTO: Decodable, Identifiable {
    let id: String
    let kind: UniversalCaptureKind
    let title: String
    let details: String?
    let startTime: String?
    let endTime: String?
    let dueDate: String?
    let allDay: Bool
    let assignedTo: String?
    let assignedToName: String?
    let confidence: Double
    let sourceText: String?
}

struct CaptureEventRequest: Encodable {
    let id: String
    let title: String
    let description: String?
    let startTime: String
    let endTime: String?
    let allDay: Bool
    let recurrenceRule: String? = nil
    let location: String? = nil
    let assignedTo: String?
}

struct CaptureTaskRequest: Encodable {
    let id: String
    let title: String
    let description: String?
    let assignees: [AssigneeInput]?
    let dueDate: String?
    let category: String = "other"
    let recurrenceRule: String? = nil
    let priority: Int = 2
    let actionableFrom: String? = nil
}

struct CaptureShoppingRequest: Encodable {
    let id: String
    let name: String
    let quantity: String?
    let category: String?
    let clientId: String
    let clientTimestamp: String
}

struct EditableCaptureProposal: Identifiable, Equatable {
    let id: String
    let operationId: String
    var kind: UniversalCaptureKind
    var title: String
    var details: String
    var quantity: String
    var category: String
    var startDate: Date
    var endDate: Date
    var hasEndDate: Bool
    var dueDate: Date
    var hasDueDate: Bool
    var allDay: Bool
    var assignedTo: String?
    var isIncluded: Bool

    init(dto: UniversalCaptureProposalDTO) {
        id = dto.id
        operationId = UUID().uuidString
        kind = dto.kind
        title = dto.title
        details = dto.details ?? ""
        quantity = ""
        category = ""
        startDate = dto.startTime.flatMap(ISODateParser.parse) ?? Date()
        endDate =
            dto.endTime.flatMap(ISODateParser.parse)
            ?? Calendar.current.date(byAdding: .hour, value: 1, to: startDate)
            ?? startDate
        hasEndDate = dto.endTime != nil
        dueDate = dto.dueDate.flatMap(ISODateParser.parse) ?? Date()
        hasDueDate = dto.dueDate != nil
        allDay = dto.allDay
        assignedTo = dto.assignedTo
        isIncluded = true
    }

    init(kind: UniversalCaptureKind, date: Date = Date()) {
        id = UUID().uuidString
        operationId = UUID().uuidString
        self.kind = kind
        title = ""
        details = ""
        quantity = ""
        category = ""
        startDate = date
        endDate = Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date
        hasEndDate = false
        dueDate = date
        hasDueDate = false
        allDay = kind == .event
        assignedTo = nil
        isIncluded = true
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDetails: String? {
        let value = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var trimmedQuantity: String? {
        let value = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var trimmedCategory: String? {
        let value = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func eventRequest() -> CaptureEventRequest {
        let start =
            allDay
            ? ISODateParser.stringDateOnly(from: startDate)
            : ISODateParser.stringNoFractional(from: startDate)
        let end =
            hasEndDate && !allDay
            ? ISODateParser.stringNoFractional(from: endDate)
            : nil
        return CaptureEventRequest(
            id: operationId,
            title: trimmedTitle,
            description: trimmedDetails,
            startTime: start,
            endTime: end,
            allDay: allDay,
            assignedTo: assignedTo
        )
    }

    func taskRequest(member: FamilyMemberDTO?) -> CaptureTaskRequest {
        let assignees = member.map {
            [AssigneeInput(assigneeId: $0.id, assigneeType: $0.memberType)]
        }
        return CaptureTaskRequest(
            id: operationId,
            title: trimmedTitle,
            description: trimmedDetails,
            assignees: assignees,
            dueDate: hasDueDate ? ISODateParser.stringNoFractional(from: dueDate) : nil
        )
    }

    func shoppingRequest(clientId: String, now: Date = Date()) -> CaptureShoppingRequest {
        CaptureShoppingRequest(
            id: operationId,
            name: trimmedTitle,
            quantity: trimmedQuantity,
            category: trimmedCategory,
            clientId: clientId,
            clientTimestamp: ISODateParser.string(from: now)
        )
    }
}
