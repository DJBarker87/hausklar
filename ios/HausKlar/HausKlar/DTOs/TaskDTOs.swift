import Foundation

// MARK: - Task DTOs

/// Data transfer object for task assignees in API responses.
struct TaskAssigneeDTO: Codable, Identifiable {
    let id: String
    let assigneeId: String
    let assigneeType: String
    let assigneeName: String?
    let completedAt: String?
    let completedBy: String?
}

/// Data transfer object for family members (used in assignee picker).
struct FamilyMemberDTO: Codable, Identifiable {
    let id: String
    let name: String
    let memberType: String
    let avatarURL: String?

    init(id: String, name: String, memberType: String, avatarURL: String? = nil) {
        self.id = id
        self.name = name
        self.memberType = memberType
        self.avatarURL = avatarURL
    }
}

/// Encodable input for assigning a person to a task.
struct AssigneeInput: Encodable, Equatable {
    let assigneeId: String
    let assigneeType: String
}

/// Data transfer object for tasks received from / sent to the API.
struct TaskDTO: Codable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let assignedTo: String?
    let dueDate: String?
    let completedAt: String?
    let category: String?
    let recurrenceRule: String?
    let priority: Int
    let createdAt: String
    let updatedAt: String
    let createdBy: String?
    let actionableFrom: String?
    let assignees: [TaskAssigneeDTO]
    let sourceDocumentId: String?
    let sourceDocument: SourceDocumentDTO?
    let sourceEventId: String?
    let prepOccurrenceId: String?
    let prepOccurrenceStart: String?
    let readOnly: Bool
    let managedSource: ManagedSourceDTO?

    var isManaged: Bool { managedSource != nil }

    var isFinanceManaged: Bool {
        managedSource?.kind.hasPrefix("finance_") == true
    }

    var isLibraryManaged: Bool {
        managedSource?.kind == "library_loan"
    }

    var managedCategoryLabel: String? {
        if isLibraryManaged { return "Library" }
        if isFinanceManaged { return "Money" }
        return nil
    }

    var managedLocationLabel: String? {
        if isLibraryManaged { return "Library books" }
        if isFinanceManaged { return "Finance" }
        return nil
    }

    init(
        id: String,
        title: String,
        description: String?,
        assignedTo: String?,
        dueDate: String?,
        completedAt: String?,
        category: String?,
        recurrenceRule: String?,
        priority: Int,
        createdAt: String,
        updatedAt: String,
        createdBy: String?,
        actionableFrom: String?,
        assignees: [TaskAssigneeDTO],
        sourceDocumentId: String? = nil,
        sourceDocument: SourceDocumentDTO? = nil,
        sourceEventId: String? = nil,
        prepOccurrenceId: String? = nil,
        prepOccurrenceStart: String? = nil,
        readOnly: Bool = false,
        managedSource: ManagedSourceDTO? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.assignedTo = assignedTo
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.category = category
        self.recurrenceRule = recurrenceRule
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.actionableFrom = actionableFrom
        self.assignees = assignees
        self.sourceDocumentId = sourceDocumentId
        self.sourceDocument = sourceDocument
        self.sourceEventId = sourceEventId
        self.prepOccurrenceId = prepOccurrenceId
        self.prepOccurrenceStart = prepOccurrenceStart
        self.readOnly = readOnly
        self.managedSource = managedSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        assignedTo = try container.decodeIfPresent(String.self, forKey: .assignedTo)
        dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        recurrenceRule = try container.decodeIfPresent(String.self, forKey: .recurrenceRule)
        priority = try container.decode(Int.self, forKey: .priority)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        createdBy = try container.decodeIfPresent(String.self, forKey: .createdBy)
        actionableFrom = try container.decodeIfPresent(String.self, forKey: .actionableFrom)
        assignees = try container.decodeIfPresent([TaskAssigneeDTO].self, forKey: .assignees) ?? []
        sourceDocumentId = try container.decodeIfPresent(String.self, forKey: .sourceDocumentId)
        sourceDocument = try container.decodeIfPresent(SourceDocumentDTO.self, forKey: .sourceDocument)
        sourceEventId = try container.decodeIfPresent(String.self, forKey: .sourceEventId)
        prepOccurrenceId = try container.decodeIfPresent(String.self, forKey: .prepOccurrenceId)
        prepOccurrenceStart = try container.decodeIfPresent(String.self, forKey: .prepOccurrenceStart)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        managedSource = try container.decodeIfPresent(ManagedSourceDTO.self, forKey: .managedSource)
    }
}
