import Foundation

enum OfflineHTTPMutationStatus: String, Codable, Sendable {
    case pending
    case inFlight = "in_flight"
    case retryable
    case permanent
}

struct QueuedHTTPMutation: Codable, Sendable {
    let id: String
    let identity: String
    let method: String
    let path: String
    var body: Data?
    let contentType: String?
    let createdAt: Date
    var status: OfflineHTTPMutationStatus
    var retryCount: Int
    var nextAttemptAt: Date?
    var lastAttemptAt: Date?
    var lastError: String?
    var lastStatusCode: Int?
    var encodedBytes: Int
    var bodyFileName: String?

    init(
        id: String,
        identity: String,
        method: String,
        path: String,
        body: Data?,
        contentType: String?,
        createdAt: Date,
        status: OfflineHTTPMutationStatus = .pending,
        retryCount: Int = 0,
        nextAttemptAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil,
        lastStatusCode: Int? = nil,
        encodedBytes: Int? = nil,
        bodyFileName: String? = nil
    ) {
        self.id = id
        self.identity = identity
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType
        self.createdAt = createdAt
        self.status = status
        self.retryCount = retryCount
        self.nextAttemptAt = nextAttemptAt
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.lastStatusCode = lastStatusCode
        self.encodedBytes = encodedBytes ?? body?.count ?? 0
        self.bodyFileName = bodyFileName
    }

    private enum CodingKeys: String, CodingKey {
        case id, identity, method, path, body, contentType, createdAt, status
        case retryCount, nextAttemptAt, lastAttemptAt, lastError, lastStatusCode
        case encodedBytes, bodyFileName
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        identity = try values.decode(String.self, forKey: .identity)
        method = try values.decode(String.self, forKey: .method)
        path = try values.decode(String.self, forKey: .path)
        body = try values.decodeIfPresent(Data.self, forKey: .body)
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        status =
            try values.decodeIfPresent(OfflineHTTPMutationStatus.self, forKey: .status)
            ?? .pending
        retryCount = try values.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        nextAttemptAt = try values.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        lastStatusCode = try values.decodeIfPresent(Int.self, forKey: .lastStatusCode)
        encodedBytes =
            try values.decodeIfPresent(Int.self, forKey: .encodedBytes)
            ?? body?.count ?? 0
        bodyFileName = try values.decodeIfPresent(String.self, forKey: .bodyFileName)
    }
}

struct OfflineHTTPMutationSummary: Equatable, Sendable {
    let id: String
    let method: String
    let path: String
    let status: OfflineHTTPMutationStatus
    let retryCount: Int
    let nextAttemptAt: Date?
    let lastError: String?
    let lastStatusCode: Int?
    let encodedBytes: Int
}

enum OfflineHTTPMutationStoreError: LocalizedError {
    case capacityExceeded
    case missingBodyFile
    case corruptStore

    var errorDescription: String? {
        switch self {
        case .capacityExceeded: return "The offline HTTP queue has reached its storage limit."
        case .missingBodyFile: return "A queued upload body is missing."
        case .corruptStore: return "The offline HTTP queue is corrupt."
        }
    }
}
