import Foundation

enum DocumentCategory: String, CaseIterable, Identifiable, Codable {
    case school
    case medical
    case childcare
    case identity
    case finance
    case activities
    case household
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .school: "School"
        case .medical: "Medical"
        case .childcare: "Childcare"
        case .identity: "Identity"
        case .finance: "Finance"
        case .activities: "Activities"
        case .household: "Household"
        case .other: "Uncategorised"
        }
    }

    var icon: String {
        switch self {
        case .school: "graduationcap.fill"
        case .medical: "cross.case.fill"
        case .childcare: "figure.and.child.holdinghands"
        case .identity: "person.example_e67ce73d.rectangle"
        case .finance: "sterlingsign.circle.fill"
        case .activities: "figure.run"
        case .household: "house.fill"
        case .other: "doc.fill"
        }
    }
}

enum CaptureSuggestionKind: String, CaseIterable, Identifiable, Codable, Hashable {
    case event
    case task

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String { self == .event ? "calendar.badge.plus" : "checklist" }
}

struct DocumentPersonDTO: Codable, Identifiable {
    let id: String
    let personId: String
    let personName: String
    let personType: String
}

/// Compact document metadata embedded in events and tasks. The original file
/// remains in the authenticated document store and is downloaded only when the
/// user explicitly opens it.
struct SourceDocumentDTO: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let originalFilename: String
    let mediaType: String
    let fileSize: Int
    let downloadUrl: String

    init(
        id: String,
        title: String,
        originalFilename: String,
        mediaType: String,
        fileSize: Int,
        downloadUrl: String
    ) {
        self.id = id
        self.title = title
        self.originalFilename = originalFilename
        self.mediaType = mediaType
        self.fileSize = fileSize
        self.downloadUrl = downloadUrl
    }

    init(document: DocumentDTO) {
        self.init(
            id: document.id,
            title: document.title,
            originalFilename: document.originalFilename,
            mediaType: document.mediaType,
            fileSize: document.fileSize,
            downloadUrl: document.downloadUrl
        )
    }
}

struct LinkedDocumentEventDTO: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let startTime: String
    let endTime: String?
    let allDay: Bool
}

struct LinkedDocumentTaskDTO: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let dueDate: String?
    let completedAt: String?
}

/// Encodes `nil` as JSON null, which is required to explicitly unlink an
/// existing document rather than omitting the field as unchanged.
struct SourceDocumentLinkUpdateRequest: Encodable {
    let sourceDocumentId: String?

    enum CodingKeys: String, CodingKey { case sourceDocumentId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceDocumentId, forKey: .sourceDocumentId)
    }
}

struct CaptureSuggestionDTO: Codable, Identifiable {
    let id: String
    let documentId: String
    let kind: CaptureSuggestionKind
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
    let status: String
    let resultId: String?
    let resultStatus: String
    let resultCompletedAt: String?
    let createdAt: String
    let updatedAt: String
}

struct CaptureSuggestionDraft: Encodable, Identifiable, Hashable {
    var id: String
    var kind: CaptureSuggestionKind
    var title: String
    var details: String?
    var startTime: String?
    var endTime: String?
    var dueDate: String?
    var allDay: Bool
    var assignedTo: String?
    var confidence: Double
    var sourceText: String?
    var isIncluded: Bool

    init(
        id: String = UUID().uuidString,
        kind: CaptureSuggestionKind,
        title: String,
        details: String? = nil,
        startTime: String? = nil,
        endTime: String? = nil,
        dueDate: String? = nil,
        allDay: Bool = true,
        assignedTo: String? = nil,
        confidence: Double = 0.5,
        sourceText: String? = nil,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.startTime = startTime
        self.endTime = endTime
        self.dueDate = dueDate
        self.allDay = allDay
        self.assignedTo = assignedTo
        self.confidence = confidence
        self.sourceText = sourceText
        self.isIncluded = isIncluded
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, details, startTime, endTime, dueDate, allDay
        case assignedTo, confidence, sourceText
    }
}

struct DocumentDTO: Codable, Identifiable {
    let id: String
    let title: String
    let originalFilename: String
    let mediaType: String
    let fileSize: Int
    let sha256: String
    let source: String
    let category: DocumentCategory
    let categoryConfidence: Double?
    let status: String
    let documentDate: String?
    let documentDateConfidence: Double?
    let pageCount: Int
    let extractedText: String?
    let notes: String?
    let processor: String
    let people: [DocumentPersonDTO]
    let suggestions: [CaptureSuggestionDTO]
    let pendingSuggestionCount: Int
    let readyForBatchFiling: Bool?
    let downloadUrl: String
    let createdAt: String
    let updatedAt: String
    let createdBy: String?
    var linkedEvents: [LinkedDocumentEventDTO]? = nil
    var linkedTasks: [LinkedDocumentTaskDTO]? = nil
}

struct DocumentStatsDTO: Codable {
    let totalDocuments: Int
    let inboxDocuments: Int
    let pendingSuggestions: Int
    let storageBytes: Int
    let storageQuotaBytes: Int
    let byPerson: [String: Int]
}

struct DocumentInboxAddressDTO: Codable {
    let configured: Bool
    let address: String?
}

struct DocumentUpdateRequest: Encodable {
    let title: String?
    let category: String?
    let status: String?
    let documentDate: String?
    let notes: String?
    let personIds: [String]?
}

struct DocumentMetadataUpdateRequest: Encodable {
    let title: String
    let category: String
    let documentDate: String?
    let notes: String?
    let personIds: [String]

    enum CodingKeys: String, CodingKey {
        case title, category, documentDate, notes, personIds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(category, forKey: .category)
        try container.encode(documentDate, forKey: .documentDate)
        try container.encode(notes, forKey: .notes)
        try container.encode(personIds, forKey: .personIds)
    }
}

struct DocumentBatchFileRequest: Encodable {
    let documentIds: [String]
}

struct DocumentBatchFileResponseDTO: Codable {
    let filedIds: [String]
    let skippedIds: [String]
}

struct SuggestionUpdateRequest: Encodable {
    let kind: String?
    let title: String?
    let details: String?
    let startTime: String?
    let endTime: String?
    let dueDate: String?
    let allDay: Bool?
    let assignedTo: String?

    init(draft: CaptureSuggestionDraft) {
        kind = draft.kind.rawValue
        title = draft.title
        details = draft.details
        startTime = draft.startTime
        endTime = draft.endTime
        dueDate = draft.dueDate
        allDay = draft.allDay
        assignedTo = draft.assignedTo
    }

    init() {
        kind = nil
        title = nil
        details = nil
        startTime = nil
        endTime = nil
        dueDate = nil
        allDay = nil
        assignedTo = nil
    }
}

struct SuggestionCreateRequest: Encodable {
    let id: String
    let kind: String
    let title: String
    let details: String?
    let startTime: String?
    let endTime: String?
    let dueDate: String?
    let allDay: Bool
    let assignedTo: String?
    let confidence: Double
    let sourceText: String?

    init(draft: CaptureSuggestionDraft) {
        id = draft.id
        kind = draft.kind.rawValue
        title = draft.title
        details = draft.details
        startTime = draft.startTime
        endTime = draft.endTime
        dueDate = draft.dueDate
        allDay = draft.allDay
        assignedTo = draft.assignedTo
        confidence = draft.confidence
        sourceText = draft.sourceText
    }
}

struct SuggestionResolutionDTO: Codable {
    let suggestionId: String
    let status: String
    let resultType: String?
    let resultId: String?
}

struct SuggestionBulkAcceptedDTO: Codable {
    let suggestionId: String
    let resultType: String
    let resultId: String
}

struct SuggestionBulkSkippedDTO: Codable {
    let suggestionId: String
    let reason: String
}

struct SuggestionBulkAcceptResponseDTO: Codable {
    let accepted: [SuggestionBulkAcceptedDTO]
    let skipped: [SuggestionBulkSkippedDTO]
}
