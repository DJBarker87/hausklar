import Foundation

enum AssistantRole: String, Codable {
    case user
    case assistant
}

enum AssistantActionKind: String, Codable {
    case calendarEvent = "calendar_event"
    case homeLights = "home_lights"
    case createTask = "create_task"
    case completeTask = "complete_task"
    case shoppingItem = "shopping_item"

    var icon: String {
        switch self {
        case .calendarEvent: return "calendar.badge.plus"
        case .homeLights: return "lightbulb.max.fill"
        case .createTask: return "checklist"
        case .completeTask: return "checkmark.circle.fill"
        case .shoppingItem: return "cart.badge.plus"
        }
    }

    var destinationTitle: String {
        switch self {
        case .calendarEvent: return "Calendar"
        case .createTask, .completeTask: return "Tasks"
        case .shoppingItem: return "Shopping"
        case .homeLights: return "House"
        }
    }

    var reviewActionTitle: String {
        switch self {
        case .calendarEvent: return "Create event"
        case .createTask: return "Create task"
        case .completeTask: return "Complete task"
        case .shoppingItem: return "Add to shopping"
        case .homeLights: return "Change house lights"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .calendarEvent: return "Create event"
        case .createTask: return "Create task"
        case .completeTask: return "Complete"
        case .shoppingItem: return "Add item"
        case .homeLights: return "Make change"
        }
    }
}

enum AssistantActionStatus: String, Codable {
    case pending
    case executing
    case executed
    case declined
    case failed
    case expired
}

struct AssistantHistoryDTO: Encodable {
    let role: AssistantRole
    let content: String
}

struct AssistantMessageRequestDTO: Encodable {
    let message: String
    let history: [AssistantHistoryDTO]
    let clientNow: String
    let timezone: String
}

enum AssistantActionPreview: Equatable {
    case calendar(CalendarActionPreview)
    case task(TaskActionPreview)
    case shopping(ShoppingActionPreview)

    var kind: AssistantActionKind {
        switch self {
        case .calendar: return .calendarEvent
        case .task: return .createTask
        case .shopping: return .shoppingItem
        }
    }

    var title: String {
        switch self {
        case .calendar(let preview): return preview.title
        case .task(let preview): return preview.title
        case .shopping(let preview): return preview.name
        }
    }
}

extension AssistantActionPreview: Decodable {
    private enum CodingKeys: String, CodingKey { case kind }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(AssistantActionKind.self, forKey: .kind) {
        case .calendarEvent:
            self = .calendar(try CalendarActionPreview(from: decoder))
        case .createTask:
            self = .task(try TaskActionPreview(from: decoder))
        case .shoppingItem:
            self = .shopping(try ShoppingActionPreview(from: decoder))
        case .homeLights, .completeTask:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "This assistant action kind does not have an editable preview."
            )
        }
    }
}

struct CalendarActionPreview: Codable, Equatable {
    let kind: AssistantActionKind
    var title: String
    var description: String?
    var startTime: String
    var endTime: String?
    var allDay: Bool
    var recurrenceRule: String?
    var assignedTo: String?
    var termTimeOnly: Bool
}

struct TaskActionPreview: Codable, Equatable {
    let kind: AssistantActionKind
    var title: String
    var description: String?
    var dueDate: String?
    var recurrenceRule: String?
    var assignedTo: String?
    var category: String
    var priority: Int
}

struct ShoppingActionPreview: Codable, Equatable {
    let kind: AssistantActionKind
    var name: String
    var quantity: String?
    var category: String?
}

enum AssistantRecurrenceOption: String, CaseIterable, Identifiable {
    case never, daily, weekly, monthly, yearly, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        case .yearly: return "Every year"
        case .custom: return "Custom schedule"
        }
    }

    static let common: [AssistantRecurrenceOption] = [.never, .daily, .weekly, .monthly, .yearly]

    init(rule: String?) {
        guard let value = rule?.uppercased(), !value.isEmpty else {
            self = .never
            return
        }
        if value.contains("FREQ=DAILY") { self = .daily }
        else if value.contains("FREQ=WEEKLY") { self = .weekly }
        else if value.contains("FREQ=MONTHLY") { self = .monthly }
        else if value.contains("FREQ=YEARLY") { self = .yearly }
        else { self = .custom }
    }

    func rule(preserving current: String?) -> String? {
        switch self {
        case .never: return nil
        case .daily: return "FREQ=DAILY"
        case .weekly:
            return AssistantRecurrenceOption(rule: current) == .weekly ? current : "FREQ=WEEKLY"
        case .monthly: return "FREQ=MONTHLY"
        case .yearly: return "FREQ=YEARLY"
        case .custom: return current
        }
    }
}

struct AssistantActionDTO: Decodable, Identifiable {
    let id: String
    let kind: AssistantActionKind
    let summary: String
    let status: AssistantActionStatus
    let expiresAt: String
    let preview: AssistantActionPreview?
    let editable: Bool

    private enum CodingKeys: String, CodingKey {
        case id, kind, summary, status, expiresAt, preview, editable
    }

    init(
        id: String,
        kind: AssistantActionKind,
        summary: String,
        status: AssistantActionStatus,
        expiresAt: String,
        preview: AssistantActionPreview? = nil,
        editable: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.status = status
        self.expiresAt = expiresAt
        self.preview = preview
        self.editable = editable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(AssistantActionKind.self, forKey: .kind)
        summary = try container.decode(String.self, forKey: .summary)
        status = try container.decode(AssistantActionStatus.self, forKey: .status)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        editable = try container.decodeIfPresent(Bool.self, forKey: .editable) ?? false
        // A present preview is part of the human confirmation boundary. Fail
        // closed if it is malformed instead of exposing an action whose actual
        // mutation details could not be reviewed.
        preview = try container.decodeIfPresent(AssistantActionPreview.self, forKey: .preview)
    }
}

struct AssistantMessageResponseDTO: Decodable {
    let answer: String
    let actions: [AssistantActionDTO]
    let processor: String
}

struct AssistantActionResultDTO: Decodable {
    let id: String
    let kind: AssistantActionKind
    let summary: String
    let status: AssistantActionStatus
    let message: String
    let resultId: String?
}

struct AssistantActionState: Identifiable, Equatable {
    let id: String
    let kind: AssistantActionKind
    var summary: String
    var status: AssistantActionStatus
    var resultMessage: String?
    var resultId: String?
    var preview: AssistantActionPreview?
    var editable: Bool

    init(_ dto: AssistantActionDTO) {
        id = dto.id
        kind = dto.kind
        summary = dto.summary
        status = dto.status
        preview = dto.preview
        editable = dto.editable && dto.preview != nil
    }
}

/// Strict, kind-specific PATCH bodies. The backend rejects fields that do not belong
/// to the selected action kind, so the app never sends an arbitrary dictionary.
enum AssistantActionUpdateRequest: Encodable {
    case calendar(CalendarActionPreview)
    case task(TaskActionPreview)
    case shopping(ShoppingActionPreview)

    private enum CodingKeys: String, CodingKey {
        case kind, title, description, startTime, endTime, allDay, recurrenceRule
        case assignedTo, termTimeOnly, dueDate, category, priority, name, quantity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .calendar(let preview):
            try container.encode(preview.kind, forKey: .kind)
            try container.encode(preview.title, forKey: .title)
            try container.encodeOptional(preview.description, forKey: .description)
            try container.encode(preview.startTime, forKey: .startTime)
            try container.encodeOptional(preview.endTime, forKey: .endTime)
            try container.encode(preview.allDay, forKey: .allDay)
            try container.encodeOptional(preview.recurrenceRule, forKey: .recurrenceRule)
            try container.encodeOptional(preview.assignedTo, forKey: .assignedTo)
            try container.encode(preview.termTimeOnly, forKey: .termTimeOnly)
        case .task(let preview):
            try container.encode(preview.kind, forKey: .kind)
            try container.encode(preview.title, forKey: .title)
            try container.encodeOptional(preview.description, forKey: .description)
            try container.encodeOptional(preview.dueDate, forKey: .dueDate)
            try container.encodeOptional(preview.recurrenceRule, forKey: .recurrenceRule)
            try container.encodeOptional(preview.assignedTo, forKey: .assignedTo)
            try container.encode(preview.category, forKey: .category)
            try container.encode(preview.priority, forKey: .priority)
        case .shopping(let preview):
            try container.encode(preview.kind, forKey: .kind)
            try container.encode(preview.name, forKey: .name)
            try container.encodeOptional(preview.quantity, forKey: .quantity)
            try container.encodeOptional(preview.category, forKey: .category)
        }
    }

    init(preview: AssistantActionPreview) {
        switch preview {
        case .calendar(let value): self = .calendar(value)
        case .task(let value): self = .task(value)
        case .shopping(let value): self = .shopping(value)
        }
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}

struct AssistantChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: AssistantRole
    let content: String
    var actions: [AssistantActionState]

    init(
        id: UUID = UUID(),
        role: AssistantRole,
        content: String,
        actions: [AssistantActionState] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.actions = actions
    }
}
