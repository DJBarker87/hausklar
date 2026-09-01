import Foundation
import SwiftData

/// Operation type for offline actions.
enum OfflineOperation: String, Codable {
    case create, update, delete
}

/// Sync status for offline actions.
enum OfflineStatus: String, Codable {
    case pending
    /// A caller-managed foreground transport owns this durable operation. Normal
    /// sync must not claim it while that process-local attempt is still live;
    /// crash recovery releases an unowned value back to `pending`.
    case directAttempt = "direct_attempt"
    case inFlight = "in_flight"
    case retryable
    case permanent

    // Legacy values remain decodable while the migration plan advances. Queue
    // preparation normalises them before attempting any network work.
    case syncing
    case synced
    case failed
}

/// Represents a queued offline action that will be synced to the server when connectivity returns.
/// This is the core of the Level 2 offline sync strategy.
@Model
final class OfflineAction {
    @Attribute(.unique) var id: String
    /// Operation type: create, update, delete
    var operation: OfflineOperation
    /// The backend table this action targets (e.g. "calendar_events", "tasks").
    var tableName: String
    /// UUID of the record being created/updated/deleted.
    var recordId: String
    /// JSON-encoded payload containing the record data.
    var payload: String
    var createdAt: Date
    /// Status: pending, syncing, synced, failed
    var status: OfflineStatus
    /// Number of times this action has been retried after failure.
    var retryCount: Int
    /// Earliest time an automatic retry may claim this action.
    var nextAttemptAt: Date?
    /// Most recent actual transport attempt. Crash recovery never changes it.
    var lastAttemptAt: Date?
    /// Inspectable terminal/retry reason; never used to make replay decisions.
    var lastError: String?
    /// HTTP status when one was available.
    var lastStatusCode: Int?
    /// Persisted size used to enforce a bounded queue without re-encoding every
    /// existing payload on each enqueue.
    var payloadByteCount: Int?

    init(
        id: String = UUID().uuidString,
        operation: OfflineOperation = .create,
        tableName: String = "",
        recordId: String = "",
        payload: String = "{}",
        createdAt: Date = Date(),
        status: OfflineStatus = .pending,
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        lastStatusCode: Int? = nil,
        payloadByteCount: Int? = nil
    ) {
        self.id = id
        self.operation = operation
        self.tableName = tableName
        self.recordId = recordId
        self.payload = payload
        self.createdAt = createdAt
        self.status = status
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.lastStatusCode = lastStatusCode
        self.payloadByteCount = payloadByteCount ?? payload.lengthOfBytes(using: .utf8)
    }
}
