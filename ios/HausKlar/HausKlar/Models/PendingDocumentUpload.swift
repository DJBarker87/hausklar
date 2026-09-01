import Foundation
import SwiftData

enum DocumentUploadStatus: String, Codable {
    case pending
    case uploading
    case acknowledgedPendingCleanup
    case retryableFailure
    case permanentFailure
    case complete

    /// Kept so stores written by the previous queue implementation remain
    /// decodable. Reconciliation converts it to `permanentFailure`.
    case failed

    var mayUploadAutomatically: Bool {
        switch self {
        case .pending, .retryableFailure:
            true
        case .uploading, .acknowledgedPendingCleanup, .permanentFailure, .complete, .failed:
            false
        }
    }

    var isFailure: Bool {
        switch self {
        case .retryableFailure, .permanentFailure, .failed:
            true
        case .pending, .uploading, .acknowledgedPendingCleanup, .complete:
            false
        }
    }
}

/// Durable queue entry for a captured file that has not reached the backend yet.
@Model
final class PendingDocumentUpload {
    @Attribute(.unique) var id: String
    var filePath: String
    var filename: String
    var mediaType: String
    var title: String
    var source: String
    var category: String
    var documentDate: String?
    var pageCount: Int
    var extractedText: String?
    var notes: String?
    var personIdsJSON: String
    var suggestionsJSON: String
    var useHermes: Bool
    var status: DocumentUploadStatus
    var errorMessage: String?
    var createdAt: Date

    // Optional fields provide migration-safe defaults for queues created by an
    // older app build. The server response is persisted before the staged file
    // is removed, creating a durable acknowledgement boundary.
    var acknowledgedDocumentJSON: Data?
    var acknowledgedAt: Date?
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?
    var retryCount: Int?
    var failureKind: String?

    init(
        id: String = UUID().uuidString,
        filePath: String,
        filename: String,
        mediaType: String,
        title: String,
        source: String,
        category: String,
        documentDate: String? = nil,
        pageCount: Int = 1,
        extractedText: String? = nil,
        notes: String? = nil,
        personIdsJSON: String = "[]",
        suggestionsJSON: String = "[]",
        useHermes: Bool = true,
        status: DocumentUploadStatus = .pending,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        acknowledgedDocumentJSON: Data? = nil,
        acknowledgedAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        nextAttemptAt: Date? = nil,
        retryCount: Int? = nil,
        failureKind: String? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.filename = filename
        self.mediaType = mediaType
        self.title = title
        self.source = source
        self.category = category
        self.documentDate = documentDate
        self.pageCount = pageCount
        self.extractedText = extractedText
        self.notes = notes
        self.personIdsJSON = personIdsJSON
        self.suggestionsJSON = suggestionsJSON
        self.useHermes = useHermes
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.acknowledgedDocumentJSON = acknowledgedDocumentJSON
        self.acknowledgedAt = acknowledgedAt
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.retryCount = retryCount
        self.failureKind = failureKind
    }
}
