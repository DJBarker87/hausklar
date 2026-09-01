import Foundation
import Combine
import os

struct FitnessPendingMutation: Codable, Equatable, Sendable {
    let mutationId: String
    let entityType: String
    let entityId: String
    let operation: String
    let payloadSchemaVersion: Int
    let baseRevision: Int?
    let payload: [String: JSONValue]
    let createdAtClient: String
}

struct FitnessSyncRequest: Encodable, Sendable {
    let syncProtocolVersion: Int
    let clientSchemaVersion: Int
    let clientAppVersion: String
    let clientBuild: String
    let platform: String
    let deviceId: String
    let cursor: Int
    let mutations: [FitnessPendingMutation]
}

struct FitnessSyncAccepted: Decodable, Sendable {
    let mutationId: String
    let entityId: String
    let revision: Int
}

enum FitnessMutationRejectionDisposition: String, Codable, Sendable {
    case retryable
    case permanent
}

struct FitnessSyncRejected: Decodable, Equatable, Sendable {
    let mutationId: String
    let entityId: String?
    let code: String
    let message: String?
    let retryable: Bool?
    let targetId: String?
    let targetSummary: [String: JSONValue]?
    let noticeId: String?

    var disposition: FitnessMutationRejectionDisposition {
        if let retryable { return retryable ? .retryable : .permanent }
        switch code {
        case "temporarily_unavailable", "rate_limited", "server_busy", "dependency_pending":
            return .retryable
        default:
            return .permanent
        }
    }

    var actionableMessage: String {
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        switch code {
        case "canonical_identity_changed":
            return "This record was merged on another device. Review the canonical record before editing again."
        case "temporarily_unavailable", "server_busy":
            return "The server could not apply this change yet. Review it before retrying."
        case "rate_limited":
            return "This change was deferred because the server is busy. Review it before retrying."
        case "dependency_pending":
            return "A related record must finish syncing before this change can be retried."
        default:
            return "The server did not apply this Fitness change. Review the saved values before trying again."
        }
    }
}

struct FitnessMutationRejectionRecord: Equatable, Sendable {
    let mutation: FitnessPendingMutation
    let code: String
    let message: String
    let disposition: FitnessMutationRejectionDisposition
    let targetEntityId: String?
    let targetSummary: [String: JSONValue]?
    let serverNoticeId: String?
    let attemptCount: Int
    let lastAttemptAt: String
    let rejectedAt: String
}

struct FitnessSyncChange: Decodable, Sendable {
    let sequence: Int
    let entityType: String
    let entityId: String
    let revision: Int
    let operation: String
    let data: [String: JSONValue]?
    let changedAt: String
}

struct FitnessSyncRedirect: Decodable, Sendable {
    let entityType: String
    let sourceId: String
    let targetId: String
}

struct FitnessSyncNotice: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String?
    let message: String
    let entityType: String?
    let entityId: String?
    let createdAt: String?
    let previousRevision: Int?
    let acceptedRevision: Int?
    let previousValues: [String: JSONValue]?
    let targetEntityId: String?
    let isServerNotice: Bool
    let rejectedMutationId: String?
    let rejectionDisposition: FitnessMutationRejectionDisposition?

    init(
        id: String,
        kind: String?,
        message: String,
        entityType: String?,
        entityId: String?,
        createdAt: String?,
        previousRevision: Int? = nil,
        acceptedRevision: Int? = nil,
        previousValues: [String: JSONValue]? = nil,
        targetEntityId: String? = nil,
        isServerNotice: Bool = false,
        rejectedMutationId: String? = nil,
        rejectionDisposition: FitnessMutationRejectionDisposition? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.entityType = entityType
        self.entityId = entityId
        self.createdAt = createdAt
        self.previousRevision = previousRevision
        self.acceptedRevision = acceptedRevision
        self.previousValues = previousValues
        self.targetEntityId = targetEntityId
        self.isServerNotice = isServerNotice
        self.rejectedMutationId = rejectedMutationId
        self.rejectionDisposition = rejectionDisposition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
            ?? container.decodeIfPresent(String.self, forKey: .noticeType)
        message = try container.decodeIfPresent(String.self, forKey: .message)
            ?? container.decodeIfPresent(String.self, forKey: .detail)
            ?? "Fitness data was updated on another device."
        entityType = try container.decodeIfPresent(String.self, forKey: .entityType)
        entityId = try container.decodeIfPresent(String.self, forKey: .entityId)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        previousRevision = try container.decodeIfPresent(Int.self, forKey: .previousRevision)
        acceptedRevision = try container.decodeIfPresent(Int.self, forKey: .acceptedRevision)
        previousValues = try container.decodeIfPresent([String: JSONValue].self, forKey: .previousValuesJson)
        targetEntityId = try container.decodeIfPresent(String.self, forKey: .targetEntityId)
        isServerNotice = true
        rejectedMutationId = nil
        rejectionDisposition = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, message, detail, noticeType, entityType, entityId, createdAt
        case previousRevision, acceptedRevision, previousValuesJson, targetEntityId
    }
}

struct FitnessSyncResponse: Decodable, Sendable {
    let status: String
    let currentSyncProtocolVersion: Int
    let currentClientSchemaVersion: Int
    let minimumSupportedClientSchemaVersion: Int
    let accepted: [FitnessSyncAccepted]
    let ackedMutationIds: [String]
    let rejectedMutations: [FitnessSyncRejected]
    let changes: [FitnessSyncChange]
    let redirects: [FitnessSyncRedirect]
    let notices: [FitnessSyncNotice]
    let nextCursor: Int
    var snapshotUrl: String? = nil
    var message: String? = nil
}

struct FitnessSnapshotEntity: Decodable, Sendable {
    let entityType: String
    let entityId: String
    let revision: Int
    let data: [String: JSONValue]
}

struct FitnessSnapshotResponse: Decodable, Sendable {
    let status: String
    let currentSyncProtocolVersion: Int
    let currentClientSchemaVersion: Int
    let minimumSupportedClientSchemaVersion: Int
    let generatedAt: String
    let entities: [FitnessSnapshotEntity]
    let redirects: [FitnessSyncRedirect]
    let nextCursor: Int
}

struct FitnessCompatibilityResponse: Decodable, Sendable {
    let status: String
    let message: String?
    let receivedSyncProtocolVersion: Int?
    let currentSyncProtocolVersion: Int?
    let supportedSyncProtocolVersions: [Int]?
    let receivedClientSchemaVersion: Int?
    let currentClientSchemaVersion: Int?
    let minimumSupportedClientSchemaVersion: Int?
    let entityType: String?
    let receivedPayloadSchemaVersion: Int?
    let supportedPayloadSchemaVersions: [Int]?
}

enum FitnessSyncError: LocalizedError, Sendable {
    case compatibility(statusCode: Int, response: FitnessCompatibilityResponse)
    case rejected(statusCode: Int, message: String)
    case malformedResponse
    case attemptStateNotSaved(syncError: String, persistenceError: String)

    var errorDescription: String? {
        switch self {
        case .compatibility(_, let response):
            response.message ?? "This version of HausKlar cannot safely sync Fitness yet. Update the app or server; your offline changes are still saved."
        case .rejected(_, let message): message
        case .malformedResponse: "The Fitness server returned an unreadable response. Offline changes remain queued."
        case .attemptStateNotSaved:
            "Fitness sync stopped because its retry state could not be saved. Offline changes remain queued."
        }
    }
}

@MainActor
final class FitnessSyncStatus: ObservableObject {
    static let shared = FitnessSyncStatus()
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var message: String?

    func begin() { isSyncing = true }
    func succeeded() { isSyncing = false; lastSyncedAt = Date(); message = nil }
    func failed(_ error: Error) { isSyncing = false; message = error.localizedDescription }
    func clear() { isSyncing = false; lastSyncedAt = nil; message = nil }
}

actor FitnessSyncService {
    static let shared = FitnessSyncService()
    private static let backgroundInterval: Duration = .seconds(5 * 60)
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "FitnessSyncService"
    )

    private let repository: FitnessRepository
    private let apiClient: APIClient
    private let database: FitnessDatabase
    /// Reused only while executing on this actor; the decoding strategy is
    /// identical to the former static decoder.
    private let decoder: JSONDecoder
    private var identity: String?
    private var storeLease: FitnessStoreLease?
    private var loopTask: Task<Void, Never>?
    private var syncTask: Task<Void, Error>?

    init(
        repository: FitnessRepository = .shared,
        apiClient: APIClient = .shared,
        database: FitnessDatabase = .shared
    ) {
        self.repository = repository
        self.apiClient = apiClient
        self.database = database
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    func activate(identity: String) async {
        if self.identity == identity, let storeLease {
            do {
                try database.validate(storeLease)
                return
            } catch {
                Self.logger.error(
                    "Active Fitness sync lease became invalid: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        await suspend()
        do {
            let lease = try database.lease(for: identity)
            try database.validate(lease)
            self.identity = identity
            storeLease = lease
            startPeriodicSync()
        } catch {
            Self.logger.error(
                "Fitness sync activation failed; no owner session was installed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func pausePeriodicSync() {
        loopTask?.cancel()
        loopTask = nil
    }

    func resumePeriodicSync() {
        guard storeLease != nil, loopTask == nil else { return }
        startPeriodicSync()
    }

    private func startPeriodicSync() {
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.runBackgroundCycle()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.backgroundInterval)
                } catch is CancellationError {
                    return
                } catch {
                    Self.logger.error(
                        "Fitness periodic-sync wait failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return
                }
                await self.runBackgroundCycle()
            }
        }
    }

    func suspend() async {
        identity = nil
        storeLease = nil
        let pendingSync = syncTask
        syncTask = nil
        let pendingLoop = loopTask
        loopTask = nil
        pendingSync?.cancel()
        pendingLoop?.cancel()
        if let pendingSync {
            do {
                try await pendingSync.value
            } catch is CancellationError {
                // Cancellation is the expected teardown path.
            } catch {
                Self.logger.error(
                    "Fitness sync ended while suspending: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if let pendingLoop { await pendingLoop.value }
        await MainActor.run { FitnessSyncStatus.shared.clear() }
    }

    /// One owner-scoped coordinator replaces four independent polling loops.
    /// User actions still flush immediately; this is the low-frequency safety net.
    private func runBackgroundCycle() async {
        guard storeLease != nil else { return }
        async let plannedMeals: Void = FitnessNutritionService.shared.flushPendingPlannedMeals()
        async let activities: Void = FitnessActivityService.shared.processInboxNow()
        async let photos: Void = FitnessRecoveryService.shared.flushProgressPhotos()
        async let healthKitWorkouts: Void = FitnessHealthKitService.shared.schedulePendingWorkoutImports(
            maximumTurns: 1
        )
        _ = await (plannedMeals, activities, photos, healthKitWorkouts)
        do {
            try await syncNow()
        } catch is CancellationError {
            // A profile switch cancels background work after retaining its outbox.
        } catch {
            Self.logger.error(
                "Background Fitness sync failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func syncNow() async throws {
        guard let lease = storeLease else { return }
        if let syncTask {
            return try await syncTask.value
        }
        let task = Task { [repository, apiClient, database] in
            try await database.withLease(lease) {
                await MainActor.run { FitnessSyncStatus.shared.begin() }
                // A label-referencing mutation is intentionally held in the outbox
                // until its protected original has an explicit staged-upload ack.
                await FitnessHealthKitService.shared.schedulePendingWorkoutImports(maximumTurns: 1)
                await FitnessNutritionService.shared.flushPendingLabels()
                let mutations = try await repository.pendingMutations()
                let ids = Set(mutations.map(\.mutationId))
                let request = FitnessSyncRequest(
                    syncProtocolVersion: FitnessContract.syncProtocolVersion,
                    clientSchemaVersion: FitnessContract.clientSchemaVersion,
                    clientAppVersion: FitnessContract.appVersion,
                    clientBuild: FitnessContract.buildNumber,
                    platform: "ios",
                    deviceId: try apiClient.clientId,
                    cursor: try await repository.syncCursor(),
                    mutations: mutations
                )
                do {
                    let response = try await apiClient.postHTTPResponse("/fitness/sync", body: request)
                    switch response.statusCode {
                    case 200...299:
                        let decoded = try self.decoder.decode(FitnessSyncResponse.self, from: response.data)
                        switch decoded.status {
                        case "ok":
                            try await repository.applySync(decoded, sentMutationIds: ids)
                        case "full_snapshot_required":
                            guard decoded.snapshotUrl == "/api/fitness/sync/snapshot" else {
                                throw FitnessSyncError.malformedResponse
                            }
                            let snapshot: FitnessSnapshotResponse = try await apiClient.get(
                                "/fitness/sync/snapshot",bypassCache: true
                            )
                            guard snapshot.status == "ok",
                                  snapshot.currentSyncProtocolVersion == FitnessContract.syncProtocolVersion,
                                  snapshot.currentClientSchemaVersion >= FitnessContract.clientSchemaVersion,
                                  snapshot.minimumSupportedClientSchemaVersion <= FitnessContract.clientSchemaVersion
                            else { throw FitnessSyncError.malformedResponse }
                            try await repository.applySnapshot(
                                snapshot,syncResponse: decoded,sentMutationIds: ids
                            )
                        default:
                            throw FitnessSyncError.malformedResponse
                        }
                        do {
                            try await FitnessNutritionRepository.shared.cleanupAcknowledgedLabels()
                        } catch {
                            // Both acknowledgements are already durable. Cleanup is retryable and
                            // must not turn an otherwise successful sync into a duplicate upload.
                            Self.logger.error(
                                "Acknowledged nutrition-label cleanup deferred: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                        await MainActor.run { FitnessSyncStatus.shared.succeeded() }
                    case 409, 426:
                        let compatibility: FitnessCompatibilityResponse
                        do {
                            compatibility = try self.decoder.decode(FitnessCompatibilityResponse.self, from: response.data)
                        } catch {
                            throw FitnessSyncError.malformedResponse
                        }
                        throw FitnessSyncError.compatibility(statusCode: response.statusCode, response: compatibility)
                    default:
                        let detail = (try? self.decoder.decode([String: String].self, from: response.data)["detail"])
                            ?? "Fitness sync was rejected (\(response.statusCode))."
                        throw FitnessSyncError.rejected(statusCode: response.statusCode, message: detail)
                    }
                    try await repository.markSyncAttempt(Array(ids), error: nil)
                } catch {
                    let syncError = error
                    do {
                        try await repository.markSyncAttempt(
                            Array(ids),error:syncError.localizedDescription
                        )
                    } catch {
                        let persistenceError = error
                        Self.logger.fault(
                            "Fitness sync retry state could not be saved; outbox retained. Sync error: \(syncError.localizedDescription, privacy: .public). Persistence error: \(persistenceError.localizedDescription, privacy: .public)"
                        )
                        let durableError = FitnessSyncError.attemptStateNotSaved(
                            syncError:syncError.localizedDescription,
                            persistenceError:persistenceError.localizedDescription
                        )
                        await MainActor.run { FitnessSyncStatus.shared.failed(durableError) }
                        throw durableError
                    }
                    await MainActor.run { FitnessSyncStatus.shared.failed(syncError) }
                    throw syncError
                }
            }
        }
        syncTask = task
        defer { syncTask = nil }
        try await task.value
    }

    func dismissNotice(_ notice: FitnessSyncNotice) async throws {
        guard let lease = storeLease else { throw FitnessDatabaseError.notActive }
        try await database.withLease(lease) {
            if notice.isServerNotice {
                let _: FitnessSyncNotice = try await apiClient.post(
                    "/fitness/sync/notices/\(notice.id)/dismiss", body: EmptyBody()
                )
            }
            try await repository.dismissNotice(notice.id)
        }
    }

    func retryRejectedMutation(_ mutationId: String) async throws {
        guard let lease = storeLease else { throw FitnessDatabaseError.notActive }
        let requeued = try await database.withLease(lease) {
            try await repository.retryRejectedMutation(mutationId)
        }
        guard requeued != nil else { return }
        try await syncNow()
    }
}
