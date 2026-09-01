import Foundation
import SwiftData
import os

/// Manages the offline sync queue. When the device is offline, actions are queued as
/// OfflineAction records in SwiftData. When connectivity returns, pending actions are
/// pushed to the server and remote changes are pulled down.
@MainActor
final class SyncManager: ObservableObject {

    struct OfflineQueueItem: Equatable {
        let id: String
        let operation: OfflineOperation
        let tableName: String
        let recordId: String
        let status: OfflineStatus
        let retryCount: Int
        let nextAttemptAt: Date?
        let lastError: String?
        let payloadBytes: Int
    }

    struct OfflineQueueInspection: Equatable {
        let items: [OfflineQueueItem]
        let encodedBytes: Int
        let errorDescription: String?

        var permanentCount: Int { items.filter { $0.status == .permanent }.count }
        var retryableCount: Int { items.filter { $0.status == .retryable }.count }
    }

    /// A capability for one installed local identity generation. Callers capture
    /// this before starting network work and must present the same lease before
    /// writing an offline fallback, so an old request cannot queue into a newer
    /// account's global SwiftData store.
    struct IdentityLease: Equatable, Sendable {
        fileprivate let identity: String
        fileprivate let epoch: Int
    }

    enum DurableActionError: LocalizedError {
        case staleIdentity
        case invalidAction
        case invalidPayload
        case queueFull
        case duplicateOperation
        case missingOperation
        case invalidOperationState
        case invalidAcknowledgement(String)

        var errorDescription: String? {
            switch self {
            case .staleIdentity:
                "The active account changed before the operation could be saved."
            case .invalidAction:
                "The durable operation is not valid."
            case .invalidPayload:
                "The durable operation payload is not valid JSON."
            case .queueFull:
                "The durable offline queue is full."
            case .duplicateOperation:
                "That durable operation already exists."
            case .missingOperation:
                "The durable operation could not be found."
            case .invalidOperationState:
                "The durable operation is not owned by this direct attempt."
            case .invalidAcknowledgement(let reason):
                reason
            }
        }
    }

    /// Every typed mutation follows this lifecycle so an optimistic SwiftData
    /// mirror and its exact replay operation cannot diverge. Presentation code
    /// may distinguish a normal queued write from a dead letter without having
    /// to reproduce queue transition rules.
    enum DurableMutationOutcome<Value> {
        case acknowledged(Value)
        case queued
        case stagingFailed(Error)
        case acknowledgementPending(Value, Error)
        case transportFailed(status: OfflineStatus?, error: Error)
    }

    private static let logger = Logger(subsystem: "org.example.hausklar", category: "SyncManager")

    // MARK: - Singleton

    /// Shared instance used by ViewModels. MainTabView also creates this via @StateObject
    /// for SwiftUI lifecycle, but ViewModels should always use `.shared`.
    static let shared = SyncManager()

    // MARK: - Private Types (uses shared JSONValue from Models/JSONValue.swift)

    private struct SyncPushItem: Encodable {
        let operationId: String
        let operation: String
        let tableName: String
        let recordId: String
        let payload: [String: JSONValue]?
        let clientId: String
        let clientTimestamp: String
    }

    private struct SyncPushPayload: Encodable {
        let items: [SyncPushItem]
    }

    private struct RecordQueueKey: Hashable {
        let tableName: String
        let recordId: String
    }

    struct SyncPushResult: Decodable {
        let operationId: String?
        let recordId: String
        let status: String
        let detail: String?
        let warnings: [SafetyWarningDTO]

        private enum CodingKeys: String, CodingKey {
            case operationId, recordId, status, detail, warnings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
            recordId = try container.decode(String.self, forKey: .recordId)
            status = try container.decode(String.self, forKey: .status)
            detail = try container.decodeIfPresent(String.self, forKey: .detail)
            warnings = try container.decodeIfPresent([SafetyWarningDTO].self, forKey: .warnings) ?? []
        }
    }

    struct SyncPushResponse: Decodable {
        let results: [SyncPushResult]
    }

    private struct PullResponse: Decodable {
        let records: [SyncPullRecord]
        let serverTimestamp: String
        let nextCursor: String?
        let hasMore: Bool

        private enum CodingKeys: String, CodingKey {
            case records, serverTimestamp, nextCursor, hasMore
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            records = try container.decode([SyncPullRecord].self, forKey: .records)
            serverTimestamp = try container.decode(String.self, forKey: .serverTimestamp)
            nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
            hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        }
    }

    struct SyncPullRecord: Decodable {
        let tableName: String
        let recordId: String
        let operation: String
        let data: [String: JSONValue]?
    }

    // MARK: - Constants

    /// Maximum number of retries before an action is permanently marked as failed.
    private static let maxRetryCount = 5
    static let maxOfflineActionCount = 500
    static let maxOfflineActionBytes = 10 * 1_024 * 1_024
    static let maxOfflineActionPayloadBytes = 512 * 1_024
    private static let maxPullPages = 1_000
    private static let baseRetryDelay: TimeInterval = 5
    private static let maxRetryDelay: TimeInterval = 15 * 60

    /// Normal auto-sync cadence while syncs are succeeding.
    private static let baseSyncInterval: TimeInterval = 5 * 60

    /// Ceiling for the exponential backoff delay after repeated sync failures.
    private static let maxSyncInterval: TimeInterval = 15 * 60

    // MARK: - Published State

    @Published var isSyncing: Bool = false
    @Published var lastSyncTimestamp: String?
    @Published var medicineSafetyWarnings: [SafetyWarningDTO] = []
    @Published var showMedicineSafetyWarning = false

    // MARK: - Dependencies

    private let client: APIClient
    private let defaults: UserDefaults
    private let now: () -> Date
    private let retryJitter: () -> Double
    private let saveQueueContext: (ModelContext) throws -> Void
    private var autoSyncTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var syncTaskID: UUID?
    private var consecutiveFailures = 0
    private let lastSyncKey = "sync.lastSyncTimestamp"
    private var activeIdentity: String?
    private var identityEpoch = 0
    /// Process-local counterparts to durable `.directAttempt` claims. An entry
    /// without a live owner is crash residue and is released by queue recovery.
    private var liveDirectAttemptIDs: Set<String> = []

    init(
        client: APIClient = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        retryJitter: @escaping () -> Double = { Double.random(in: 0.8...1.2) },
        saveQueueContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.client = client
        self.defaults = defaults
        self.now = now
        self.retryJitter = retryJitter
        self.saveQueueContext = saveQueueContext
        lastSyncTimestamp = defaults.string(forKey: lastSyncKey)
    }

    var isIdentityActive: Bool { activeIdentity != nil }

    var currentIdentityLease: IdentityLease? {
        guard let activeIdentity else { return nil }
        return IdentityLease(identity: activeIdentity, epoch: identityEpoch)
    }

    /// Runs one local mutation behind a temporary undo group. On the tested
    /// iOS 17.5 simulator with SDK 26, `rollback()` alone left same-turn changes
    /// visible after an injected save failure. The undo group restores inserts,
    /// edits and deletes to the last durable state before an error can return.
    private func saveAtomically(
        modelContext: ModelContext,
        applyChanges: () throws -> Void
    ) throws {
        let previousUndoManager = modelContext.undoManager
        let transactionUndoManager = UndoManager()
        modelContext.undoManager = transactionUndoManager
        transactionUndoManager.beginUndoGrouping()
        defer {
            transactionUndoManager.removeAllActions()
            modelContext.undoManager = previousUndoManager
        }

        do {
            try applyChanges()
            modelContext.processPendingChanges()
            transactionUndoManager.endUndoGrouping()
            try saveQueueContext(modelContext)
        } catch {
            modelContext.processPendingChanges()
            if transactionUndoManager.groupingLevel > 0 {
                transactionUndoManager.endUndoGrouping()
            }
            if transactionUndoManager.canUndo {
                transactionUndoManager.undo()
                modelContext.processPendingChanges()
            } else {
                modelContext.rollback()
            }
            throw error
        }
    }

    /// Enables sync only after AppState has verified or reset the local-store owner.
    func activate(identity: String) {
        liveDirectAttemptIDs.removeAll()
        activeIdentity = identity
        identityEpoch += 1
    }

    /// Stops every sync path, waits for the current loop to unwind, and removes the
    /// cursor so a subsequent account can never inherit another account's epoch.
    func suspendAndReset() async {
        activeIdentity = nil
        identityEpoch += 1
        let task = autoSyncTask
        autoSyncTask?.cancel()
        autoSyncTask = nil
        let inFlightSync = syncTask
        syncTask?.cancel()
        syncTask = nil
        syncTaskID = nil
        await task?.value
        await inFlightSync?.value
        isSyncing = false
        consecutiveFailures = 0
        lastSyncTimestamp = nil
        defaults.removeObject(forKey: lastSyncKey)
        acknowledgeMedicineSafetyWarnings()
        liveDirectAttemptIDs.removeAll()
    }

    // MARK: - Offline Queue

    /// Queues an action to be replayed when the device comes back online.
    /// Call this instead of the API client when NetworkMonitor.isConnected is false.
    @discardableResult
    func queueOfflineAction(
        modelContext: ModelContext,
        operation: String,
        tableName: String,
        recordId: String,
        payload: [String: Any]? = nil,
        expectedIdentityLease: IdentityLease
    ) -> Bool {
        guard currentIdentityLease == expectedIdentityLease else {
            Self.logger.error("Refused to queue an offline action for a stale local identity")
            return false
        }
        guard let offlineOperation = OfflineOperation(rawValue: operation) else {
            Self.logger.error("Refused to queue an unsupported offline operation")
            return false
        }
        var payloadJSON = "{}"
        if let payload {
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                Self.logger.error("Refused to queue an invalid JSON payload")
                return false
            }
            payloadJSON = json
        }
        let payloadBytes = payloadJSON.lengthOfBytes(using: .utf8)
        guard payloadBytes <= Self.maxOfflineActionPayloadBytes else {
            Self.logger.error("Refused an offline action whose payload exceeds the per-item limit")
            return false
        }
        let existing: [OfflineAction]
        do {
            existing = try modelContext.fetch(FetchDescriptor<OfflineAction>())
        } catch {
            Self.logger.error("Refused to queue because the durable queue could not be inspected: \(error.localizedDescription)")
            return false
        }
        let active = existing.filter { $0.status != .synced }
        let existingBytes = active.reduce(0) {
            $0 + ($1.payloadByteCount ?? $1.payload.lengthOfBytes(using: .utf8))
        }
        guard active.count < Self.maxOfflineActionCount,
              existingBytes + payloadBytes <= Self.maxOfflineActionBytes else {
            Self.logger.error("Refused an offline action because the durable queue is full")
            return false
        }

        let action = OfflineAction(
            operation: offlineOperation,
            tableName: tableName,
            recordId: recordId,
            payload: payloadJSON,
            status: .pending,
            payloadByteCount: payloadBytes
        )
        do {
            try saveAtomically(modelContext: modelContext) {
                modelContext.insert(action)
            }
            return true
        } catch {
            Self.logger.error("Failed to persist offline action: \(error.localizedDescription)")
            return false
        }
    }

    /// Persists a caller's optimistic local mutation and its exact replay intent
    /// with one `ModelContext.save()`. No transport may start until this returns.
    /// The action ID may deliberately equal a client-generated record ID so every
    /// direct/replay path has one stable identity.
    @discardableResult
    func stageDurableAction(
        modelContext: ModelContext,
        actionID: String,
        operation: OfflineOperation,
        tableName: String,
        recordId: String,
        payload: [String: Any]?,
        initialStatus: OfflineStatus = .directAttempt,
        deferBehindExistingRecordActions: Bool = false,
        expectedIdentityLease: IdentityLease,
        applyLocalMutation: () throws -> Void
    ) throws -> OfflineAction {
        guard currentIdentityLease == expectedIdentityLease else {
            throw DurableActionError.staleIdentity
        }
        guard !actionID.isEmpty, !tableName.isEmpty, !recordId.isEmpty,
              initialStatus == .directAttempt || initialStatus == .pending else {
            throw DurableActionError.invalidAction
        }

        let payloadJSON: String
        if let payload {
            guard JSONSerialization.isValidJSONObject(payload) else {
                throw DurableActionError.invalidPayload
            }
            let data: Data
            do {
                data = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.sortedKeys]
                )
            } catch {
                throw DurableActionError.invalidPayload
            }
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw DurableActionError.invalidPayload
            }
            payloadJSON = encoded
        } else {
            payloadJSON = "{}"
        }
        let payloadBytes = payloadJSON.lengthOfBytes(using: .utf8)
        guard payloadBytes <= Self.maxOfflineActionPayloadBytes else {
            throw DurableActionError.queueFull
        }

        let existing = try modelContext.fetch(FetchDescriptor<OfflineAction>())
        guard !existing.contains(where: { $0.id == actionID }) else {
            throw DurableActionError.duplicateOperation
        }
        let active = existing.filter { $0.status != .synced }
        let existingBytes = active.reduce(0) {
            $0 + ($1.payloadByteCount ?? $1.payload.lengthOfBytes(using: .utf8))
        }
        let (totalBytes, overflow) = existingBytes.addingReportingOverflow(payloadBytes)
        guard active.count < Self.maxOfflineActionCount,
              !overflow,
              totalBytes <= Self.maxOfflineActionBytes else {
            throw DurableActionError.queueFull
        }

        let effectiveStatus: OfflineStatus
        if deferBehindExistingRecordActions,
           active.contains(where: {
               $0.tableName == tableName && $0.recordId == recordId
           }) {
            effectiveStatus = .pending
        } else {
            effectiveStatus = initialStatus
        }
        let stagedAt = now()
        let action = OfflineAction(
            id: actionID,
            operation: operation,
            tableName: tableName,
            recordId: recordId,
            payload: payloadJSON,
            createdAt: stagedAt,
            status: effectiveStatus,
            lastAttemptAt: effectiveStatus == .directAttempt ? stagedAt : nil,
            payloadByteCount: payloadBytes
        )
        do {
            try saveAtomically(modelContext: modelContext) {
                try applyLocalMutation()
                modelContext.insert(action)
            }
        } catch {
            throw error
        }
        if effectiveStatus == .directAttempt {
            liveDirectAttemptIDs.insert(actionID)
        }
        return action
    }

    /// Owns the complete foreground lifecycle for a typed durable mutation.
    /// The first save commits the optimistic mirror and replay intent together;
    /// the second commits the acknowledged server representation while deleting
    /// that same operation. Any interrupted transition remains replayable.
    func performDurableMutation<Value>(
        modelContext: ModelContext,
        actionID: String,
        operation: OfflineOperation,
        tableName: String,
        recordId: String,
        payload: [String: Any]?,
        expectedIdentityLease: IdentityLease,
        deferBehindExistingRecordActions: Bool = true,
        applyLocalMutation: () throws -> Void,
        onStaged: () async -> Void = {},
        transport: () async throws -> Value,
        validateAcknowledgement: (Value) -> String? = { _ in nil },
        applyAcknowledgedResult: (Value) throws -> Void
    ) async -> DurableMutationOutcome<Value> {
        let action: OfflineAction
        do {
            action = try stageDurableAction(
                modelContext: modelContext,
                actionID: actionID,
                operation: operation,
                tableName: tableName,
                recordId: recordId,
                payload: payload,
                initialStatus: .directAttempt,
                deferBehindExistingRecordActions: deferBehindExistingRecordActions,
                expectedIdentityLease: expectedIdentityLease,
                applyLocalMutation: applyLocalMutation
            )
        } catch {
            return .stagingFailed(error)
        }

        await onStaged()
        guard action.status == .directAttempt else { return .queued }

        do {
            let value = try await transport()
            if let reason = validateAcknowledgement(value) {
                let protocolError = DurableActionError.invalidAcknowledgement(reason)
                do {
                    try markDirectAttemptPermanent(
                        id: actionID,
                        reason: reason,
                        modelContext: modelContext,
                        expectedIdentityLease: expectedIdentityLease
                    )
                    return .transportFailed(status: .permanent, error: protocolError)
                } catch {
                    return .transportFailed(status: nil, error: protocolError)
                }
            }
            do {
                try acknowledgeDirectAttempt(
                    id: actionID,
                    modelContext: modelContext,
                    expectedIdentityLease: expectedIdentityLease
                ) {
                    try applyAcknowledgedResult(value)
                }
                return .acknowledged(value)
            } catch {
                let acknowledgementError = error
                do {
                    try releaseDirectAttempt(
                        id: actionID,
                        modelContext: modelContext,
                        expectedIdentityLease: expectedIdentityLease,
                        reason: "The server receipt could not be saved locally; exact replay is pending."
                    )
                } catch {
                    Self.logger.error(
                        "Durable acknowledgement remains crash-recoverable: \(error.localizedDescription)"
                    )
                }
                return .acknowledgementPending(value, acknowledgementError)
            }
        } catch {
            let transportError = error
            do {
                let status = try resolveDirectAttemptFailure(
                    id: actionID,
                    error: transportError,
                    modelContext: modelContext,
                    expectedIdentityLease: expectedIdentityLease
                )
                return .transportFailed(status: status, error: transportError)
            } catch {
                Self.logger.error(
                    "Durable failure state remains crash-recoverable: \(error.localizedDescription)"
                )
                return .transportFailed(status: nil, error: transportError)
            }
        }
    }

    /// Applies an acknowledged server representation and retires its exact replay
    /// operation in one save. Rollback restores both the optimistic local model
    /// and operation when persistence fails.
    func acknowledgeDirectAttempt(
        id: String,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease,
        applyAcknowledgedResult: () throws -> Void
    ) throws {
        guard currentIdentityLease == expectedIdentityLease else {
            liveDirectAttemptIDs.remove(id)
            throw DurableActionError.staleIdentity
        }
        let action = try durableAction(id: id, modelContext: modelContext)
        guard action.status == .directAttempt,
              liveDirectAttemptIDs.contains(id) else {
            liveDirectAttemptIDs.remove(id)
            throw DurableActionError.invalidOperationState
        }
        do {
            try saveAtomically(modelContext: modelContext) {
                try applyAcknowledgedResult()
                modelContext.delete(action)
            }
            liveDirectAttemptIDs.remove(id)
        } catch {
            liveDirectAttemptIDs.remove(id)
            throw error
        }
    }

    /// Releases cancellation, connectivity and authentication failures without
    /// consuming a retry. A failed save rolls back to the durable direct-attempt
    /// marker, which a later crash-recovery pass can safely release.
    func releaseDirectAttempt(
        id: String,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease,
        reason: String
    ) throws {
        try transitionDirectAttempt(
            id: id,
            modelContext: modelContext,
            expectedIdentityLease: expectedIdentityLease
        ) { action in
            action.status = .pending
            action.nextAttemptAt = nil
            action.lastError = reason
            action.lastStatusCode = nil
        }
    }

    /// Classifies a completed direct transport attempt using the same retry and
    /// dead-letter rules as normal sync. Network/auth/cancellation paths remain
    /// pending and do not inflate `retryCount`.
    @discardableResult
    func resolveDirectAttemptFailure(
        id: String,
        error: Error,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) throws -> OfflineStatus {
        if Self.isCancellation(error)
            || Self.releasesDirectAttemptWithoutRetry(error) {
            try releaseDirectAttempt(
                id: id,
                modelContext: modelContext,
                expectedIdentityLease: expectedIdentityLease,
                reason: error.localizedDescription
            )
            return .pending
        }
        if isPermanentFailure(error) {
            try markDirectAttemptPermanent(
                id: id,
                reason: error.localizedDescription,
                statusCode: Self.statusCode(from: error),
                modelContext: modelContext,
                expectedIdentityLease: expectedIdentityLease
            )
            return .permanent
        }
        var resultingStatus = OfflineStatus.retryable
        try transitionDirectAttempt(
            id: id,
            modelContext: modelContext,
            expectedIdentityLease: expectedIdentityLease
        ) { action in
            markRetryable(action, error: error)
            resultingStatus = action.status
        }
        return resultingStatus
    }

    func markDirectAttemptPermanent(
        id: String,
        reason: String,
        statusCode: Int? = nil,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) throws {
        try transitionDirectAttempt(
            id: id,
            modelContext: modelContext,
            expectedIdentityLease: expectedIdentityLease
        ) { action in
            markPermanent(action, reason: reason, statusCode: statusCode)
        }
    }

    private func transitionDirectAttempt(
        id: String,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease,
        mutation: (OfflineAction) -> Void
    ) throws {
        defer { liveDirectAttemptIDs.remove(id) }
        guard currentIdentityLease == expectedIdentityLease else {
            throw DurableActionError.staleIdentity
        }
        let action = try durableAction(id: id, modelContext: modelContext)
        guard action.status == .directAttempt else {
            throw DurableActionError.invalidOperationState
        }
        do {
            try saveAtomically(modelContext: modelContext) {
                mutation(action)
            }
        } catch {
            throw error
        }
    }

    private func durableAction(
        id: String,
        modelContext: ModelContext
    ) throws -> OfflineAction {
        let requestedID = id
        let matches = try modelContext.fetch(FetchDescriptor<OfflineAction>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count == 1, let action = matches.first else {
            throw DurableActionError.missingOperation
        }
        return action
    }

    /// A stable, user-support-friendly view of every unsent/dead-lettered item.
    /// Payload contents are intentionally omitted because they may contain family
    /// or health data; identifiers and failure reasons are sufficient to inspect
    /// and safely discard a stuck action.
    func inspectOfflineQueue(modelContext: ModelContext) -> OfflineQueueInspection {
        let actions: [OfflineAction]
        do {
            actions = try modelContext.fetch(FetchDescriptor<OfflineAction>(
                sortBy: [SortDescriptor(\.createdAt, order: .forward)]
            )).filter { $0.status != .synced }
        } catch {
            return OfflineQueueInspection(
                items: [],
                encodedBytes: 0,
                errorDescription: error.localizedDescription
            )
        }
        let items = actions.map { action in
            OfflineQueueItem(
                id: action.id,
                operation: action.operation,
                tableName: action.tableName,
                recordId: action.recordId,
                status: action.status,
                retryCount: action.retryCount,
                nextAttemptAt: action.nextAttemptAt,
                lastError: action.lastError,
                payloadBytes: action.payloadByteCount
                    ?? action.payload.lengthOfBytes(using: .utf8)
            )
        }
        return OfflineQueueInspection(
            items: items,
            encodedBytes: items.reduce(0) { $0 + $1.payloadBytes },
            errorDescription: nil
        )
    }

    @discardableResult
    func discardOfflineAction(id: String, modelContext: ModelContext) -> Bool {
        let requestedID = id
        let descriptor = FetchDescriptor<OfflineAction>(
            predicate: #Predicate { $0.id == requestedID }
        )
        let action: OfflineAction
        do {
            guard let fetched = try modelContext.fetch(descriptor).first else { return false }
            action = fetched
        } catch {
            Self.logger.error(
                "Failed to inspect the offline queue before discard: \(error.localizedDescription)"
            )
            return false
        }
        do {
            try saveAtomically(modelContext: modelContext) {
                modelContext.delete(action)
            }
            return true
        } catch {
            Self.logger.error("Failed to persist offline action discard: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Sync cycle

    /// Runs push and pull as one single-flight operation. Launch, foreground,
    /// reconnect and manual triggers all join this task instead of racing the
    /// queue, background contexts and durable cursor independently.
    func syncNow(modelContext: ModelContext) async {
        guard activeIdentity != nil else { return }
        if let syncTask {
            await syncTask.value
            return
        }

        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await pushPendingActions(modelContext: modelContext)
            guard !Task.isCancelled else { return }
            await pullRemoteChanges(modelContext: modelContext)
        }
        syncTaskID = taskID
        syncTask = task
        isSyncing = true
        await task.value
        if syncTaskID == taskID {
            syncTask = nil
            syncTaskID = nil
            isSyncing = false
        }
    }

    /// Compatibility entry point. A core sync is deliberately never push-only.
    func syncPendingActions(modelContext: ModelContext) async {
        await syncNow(modelContext: modelContext)
    }

    /// Compatibility entry point. A core sync is deliberately never pull-only.
    func pullChanges(modelContext: ModelContext) async {
        await syncNow(modelContext: modelContext)
    }

    // MARK: - Push

    /// Pushes due offline actions to the server. Each action is durably claimed
    /// before transport; interruption releases the claim without consuming a
    /// retry, authentication pauses the queue, transient failures back off with
    /// jitter, and protocol/semantic 4xx failures become inspectable dead letters.
    private func pushPendingActions(modelContext: ModelContext) async {
        guard activeIdentity != nil else { return }
        let epoch = identityEpoch

        await client.flushOfflineMutations()
        guard prepareQueueForSync(modelContext: modelContext) else { return }

        let fetchDescriptor = FetchDescriptor<OfflineAction>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        let storedActions: [OfflineAction]
        do {
            storedActions = try modelContext.fetch(fetchDescriptor)
        } catch {
            Self.logger.error("Could not read the durable offline queue: \(error.localizedDescription)")
            return
        }
        let attemptTime = now()
        // Claim at most the oldest operation for each record in one push. A
        // create followed immediately by an update/delete must never overtake
        // its prerequisite when the first operation is delayed or dead-lettered.
        var occupiedRecords = Set<RecordQueueKey>()
        var retryableActions: [OfflineAction] = []
        do {
            try saveAtomically(modelContext: modelContext) {
                for action in storedActions {
                    let key = RecordQueueKey(
                        tableName: action.tableName,
                        recordId: action.recordId
                    )
                    guard occupiedRecords.insert(key).inserted else { continue }
                    guard action.status == .pending || action.status == .retryable else { continue }
                    guard action.retryCount < Self.maxRetryCount else {
                        action.status = .permanent
                        action.nextAttemptAt = nil
                        action.lastError = action.lastError ?? "Automatic retry limit reached."
                        continue
                    }
                    if action.nextAttemptAt.map({ $0 <= attemptTime }) ?? true {
                        retryableActions.append(action)
                    }
                }
            }
        } catch {
            Self.logger.error("Could not persist offline queue normalisation: \(error.localizedDescription)")
            return
        }

        guard !retryableActions.isEmpty else { return }

        // A corrupt local payload is not a transport failure. Sending it as a
        // JSON `null` would silently change the requested mutation, so retain it
        // as an inspectable dead letter and send only payloads that decode exactly.
        var decodedPayloads: [(action: OfflineAction, payload: [String: JSONValue])] = []
        var malformedActions: [OfflineAction] = []
        for action in retryableActions {
            guard let payload = decodePayload(action.payload) else {
                malformedActions.append(action)
                continue
            }
            decodedPayloads.append((action, payload))
        }
        if !malformedActions.isEmpty {
            do {
                try saveAtomically(modelContext: modelContext) {
                    for action in malformedActions {
                        markPermanent(
                            action,
                            reason: "The locally queued JSON payload is malformed and was not sent."
                        )
                    }
                }
            } catch {
                Self.logger.error("Could not persist malformed queue quarantine: \(error.localizedDescription)")
                return
            }
        }

        let pushableActions = decodedPayloads.map(\.action)
        guard !pushableActions.isEmpty else { return }
        let clientId: String
        do {
            clientId = try client.clientId
        } catch {
            Self.logger.error("Offline sync is paused: \(error.localizedDescription)")
            return
        }
        let items: [SyncPushItem] = decodedPayloads.map { entry in
            SyncPushItem(
                operationId: entry.action.id,
                operation: entry.action.operation.rawValue,
                tableName: entry.action.tableName,
                recordId: entry.action.recordId,
                payload: entry.payload,
                clientId: clientId,
                clientTimestamp: ISODateParser.string(from: entry.action.createdAt)
            )
        }

        // Persist the claim before creating network work. A process interruption
        // is recovered by prepareQueueForSync without incrementing retryCount.
        do {
            try saveAtomically(modelContext: modelContext) {
                for action in pushableActions {
                    action.status = .inFlight
                    action.lastAttemptAt = attemptTime
                    action.nextAttemptAt = nil
                }
            }
        } catch {
            Self.logger.error("Could not durably claim offline actions: \(error.localizedDescription)")
            return
        }

        do {
            let payload = SyncPushPayload(items: items)
            let response: SyncPushResponse = try await client.post("/sync/push", body: payload)
            guard activeIdentity != nil, identityEpoch == epoch else { return }
            surfaceMedicineSafetyWarnings(from: response)
            let operationResults = Dictionary(
                grouping: response.results.compactMap { result in
                    result.operationId.map { ($0, result) }
                },
                by: { $0.0 }
            )
            let duplicateOperationIDs = Set(operationResults.compactMap { entry in
                entry.value.count == 1 ? nil : entry.key
            })
            let resultsByOperationId = operationResults.compactMapValues { values in
                values.count == 1 ? values[0].1 : nil
            }
            // Legacy servers omitted operation_id. Record-ID acknowledgement is
            // safe only when exactly one queued action and one legacy result use
            // that ID; otherwise two tables/operations can share an identifier.
            let actionCountsByRecordId = Dictionary(
                grouping: pushableActions,
                by: \.recordId
            ).mapValues { $0.count }
            let legacyResultsByRecordId = Dictionary(
                grouping: response.results.filter { $0.operationId == nil },
                by: \.recordId
            )
            let resultCountsByRecordId = Dictionary(
                grouping: response.results,
                by: \.recordId
            ).mapValues { $0.count }
            var syncedCycleData = false
            var syncedPaths = Set<String>()

            do {
                try saveAtomically(modelContext: modelContext) {
                    for action in pushableActions {
                        if duplicateOperationIDs.contains(action.id) {
                            markPermanent(
                                action,
                                reason: "Sync protocol returned duplicate acknowledgements for this operation."
                            )
                            continue
                        }
                        let legacyCandidates = legacyResultsByRecordId[action.recordId]
                        let legacyResult: SyncPushResult? = {
                            guard actionCountsByRecordId[action.recordId] == 1,
                                  resultCountsByRecordId[action.recordId] == 1,
                                  legacyCandidates?.count == 1 else { return nil }
                            return legacyCandidates?.first
                        }()
                        let result = resultsByOperationId[action.id] ?? legacyResult
                        if result?.status == "accepted" {
                            if action.tableName == "cycle_settings"
                                || action.tableName == "cycle_period_starts" {
                                syncedCycleData = true
                            }
                            switch action.tableName {
                            case "calendar_events": syncedPaths.insert("/calendar")
                            case "tasks": syncedPaths.insert("/tasks")
                            case "medicine_types", "medicine_doses": syncedPaths.insert("/medicine")
                            case "naps": syncedPaths.insert("/naps")
                            case "shopping_items": syncedPaths.insert("/meals/shopping")
                            default: break
                            }
                            modelContext.delete(action)
                        } else {
                            markPermanent(
                                action,
                                reason: result?.detail
                                    ?? (result == nil
                                        ? "Sync protocol did not acknowledge this operation."
                                        : "The server rejected this operation.")
                            )
                        }
                    }
                }
            } catch {
                // The stable operation ID makes replay safe. Release every
                // recovered claim only after atomic undo restored deleted items.
                do {
                    try saveAtomically(modelContext: modelContext) {
                        for action in pushableActions where action.status == .inFlight {
                            action.status = .pending
                            action.nextAttemptAt = nil
                            action.lastError = "Server result could not be saved locally; replay is pending."
                        }
                    }
                } catch {
                    // The durable in-flight claim remains recoverable on relaunch.
                }
                Self.logger.error("Could not persist sync acknowledgements: \(error.localizedDescription)")
                return
            }
            if syncedCycleData {
                await client.invalidateCachedResource("/cycles")
                NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            }
            for path in syncedPaths {
                await client.invalidateCachedResource(path)
            }
            if syncedPaths.contains("/calendar") {
                NotificationCenter.default.post(name: .calendarDataChanged, object: nil)
            }
            if syncedPaths.contains("/tasks") {
                NotificationCenter.default.post(name: .taskDataChanged, object: nil)
            }
            if syncedPaths.contains("/meals/shopping") {
                NotificationCenter.default.post(name: .shoppingDataChanged, object: nil)
            }
        } catch {
            guard activeIdentity != nil, identityEpoch == epoch else { return }
            do {
                try saveAtomically(modelContext: modelContext) {
                    if Self.isCancellation(error) {
                        for action in pushableActions where action.status == .inFlight {
                            action.status = .pending
                            action.nextAttemptAt = nil
                        }
                    } else if (error as? APIError)?.isAuthError == true {
                        for action in pushableActions where action.status == .inFlight {
                            action.status = .pending
                            action.nextAttemptAt = nil
                            action.lastError = "Waiting for authentication before retrying."
                        }
                    } else if isPermanentFailure(error) {
                        for action in pushableActions where action.status == .inFlight {
                            markPermanent(
                                action,
                                reason: error.localizedDescription,
                                statusCode: Self.statusCode(from: error)
                            )
                        }
                    } else {
                        for action in pushableActions where action.status == .inFlight {
                            markRetryable(action, error: error)
                        }
                    }
                }
            } catch {
                Self.logger.error("Could not persist offline retry state: \(error.localizedDescription)")
            }
            Self.logger.error("Push failed: \(error.localizedDescription)")
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        if let apiError = error as? APIError,
           case .networkError(let underlying) = apiError {
            return isCancellation(underlying)
        }
        return false
    }

    private static func releasesDirectAttemptWithoutRetry(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .unauthorized, .tokenRefreshFailed, .networkError,
             .offlineQueued, .offlineQueueFull:
            return true
        case .invalidURL, .forbidden, .notFound, .conflict,
             .serverError, .decodingError:
            return false
        }
    }

    private func isPermanentFailure(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .invalidURL, .forbidden, .notFound, .conflict, .decodingError:
            return true
        case .serverError(let statusCode, _):
            return (400...499).contains(statusCode)
                && ![408, 425, 429].contains(statusCode)
        case .unauthorized, .tokenRefreshFailed, .networkError,
             .offlineQueued, .offlineQueueFull:
            return false
        }
    }

    private func markRetryable(_ action: OfflineAction, error: Error) {
        action.retryCount += 1
        action.lastError = error.localizedDescription
        action.lastStatusCode = Self.statusCode(from: error)
        guard action.retryCount < Self.maxRetryCount else {
            action.status = .permanent
            action.nextAttemptAt = nil
            return
        }
        action.status = .retryable
        let exponent = Double(max(0, action.retryCount - 1))
        let rawDelay = min(
            Self.baseRetryDelay * pow(2, exponent),
            Self.maxRetryDelay
        )
        let jitter = min(max(retryJitter(), 0.8), 1.2)
        action.nextAttemptAt = now().addingTimeInterval(rawDelay * jitter)
    }

    private func markPermanent(
        _ action: OfflineAction,
        reason: String,
        statusCode: Int? = nil
    ) {
        action.retryCount += 1
        action.status = .permanent
        action.nextAttemptAt = nil
        action.lastError = reason
        action.lastStatusCode = statusCode
    }

    /// `APIError` deliberately keeps status details private to its enum case.
    /// Queue callers still get an inspectable code for common mapped statuses.
    private static func statusCode(from error: Error) -> Int? {
        guard let apiError = error as? APIError else { return nil }
        switch apiError {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .notFound: return 404
        case .conflict: return 409
        case .serverError(let statusCode, _): return statusCode
        default: return nil
        }
    }

    func surfaceMedicineSafetyWarnings(from response: SyncPushResponse) {
        var seen = Set<String>()
        let warnings = response.results
            .filter { $0.status == "accepted" }
            .flatMap(\.warnings)
            .filter { seen.insert($0.id).inserted }
        guard !warnings.isEmpty else { return }
        medicineSafetyWarnings = warnings
        showMedicineSafetyWarning = true
    }

    func acknowledgeMedicineSafetyWarnings() {
        showMedicineSafetyWarning = false
        medicineSafetyWarnings = []
    }

    // MARK: - Pull

    /// Pulls changes from the server since the last sync timestamp.
    /// Records are applied on a background ModelContext so a large pull
    /// (e.g. the first post-login sync) cannot block the main actor.
    private func pullRemoteChanges(modelContext: ModelContext) async {
        guard activeIdentity != nil else { return }
        let epoch = identityEpoch
        do {
            let since = lastSyncTimestamp ?? "1970-01-01T00:00:00Z"
            var cursor: String?
            var snapshotTimestamp: String?
            var seenCursors = Set<String>()
            var pageCount = 0
            repeat {
                try Task.checkCancellation()
                pageCount += 1
                guard pageCount <= Self.maxPullPages else {
                    throw URLError(.dataLengthExceedsMaximum)
                }
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw URLError(.cannotParseResponse)
                }
                var queryItems = [
                    URLQueryItem(name: "since", value: since),
                    URLQueryItem(name: "limit", value: "500"),
                ]
                if let cursor {
                    queryItems.append(URLQueryItem(name: "cursor", value: cursor))
                }

                let response: PullResponse = try await client.get(
                    "/sync/pull",
                    queryItems: queryItems,
                    cachePolicy: .networkOnly
                )
                guard activeIdentity != nil, identityEpoch == epoch else { return }

                let records = response.records
                var applied = true
                if !records.isEmpty {
                    let container = modelContext.container
                    applied = await Task.detached(priority: .userInitiated) { () -> Bool in
                        let backgroundContext = ModelContext(container)
                        do {
                            try SyncPullApplier.apply(records, modelContext: backgroundContext)
                            try backgroundContext.save()
                            return true
                        } catch {
                            return false
                        }
                    }.value
                }
                guard activeIdentity != nil, identityEpoch == epoch else { return }

                // Only advance the durable timestamp after every page in the
                // server's stable snapshot has been persisted. A later-page
                // failure deliberately replays earlier pages on the next pull.
                guard applied else {
                    consecutiveFailures += 1
                    Self.logger.error("Pull save failed — leaving sync cursor so records are re-fetched")
                    return
                }
                if let snapshotTimestamp,
                   snapshotTimestamp != response.serverTimestamp {
                    throw URLError(.cannotParseResponse)
                }
                snapshotTimestamp = response.serverTimestamp
                if response.hasMore {
                    guard let nextCursor = response.nextCursor,
                          !nextCursor.isEmpty,
                          !seenCursors.contains(nextCursor) else {
                        throw URLError(.cannotParseResponse)
                    }
                    cursor = nextCursor
                } else {
                    cursor = nil
                }
            } while cursor != nil

            guard let snapshotTimestamp else { throw URLError(.cannotParseResponse) }
            lastSyncTimestamp = snapshotTimestamp
            defaults.set(snapshotTimestamp, forKey: lastSyncKey)
            consecutiveFailures = 0
        } catch {
            guard activeIdentity != nil, identityEpoch == epoch else { return }
            consecutiveFailures += 1
            Self.logger.error("Pull failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Auto Sync

    /// Starts a low-frequency safety-net sync while the device is online.
    /// Launch, foreground, reconnect and mutations already trigger immediate work.
    /// Repeated failures back off exponentially up to a 15-minute cap.
    func startAutoSync(modelContext: ModelContext, networkMonitor: NetworkMonitor) {
        guard activeIdentity != nil else {
            Self.logger.error("Refused to start auto-sync before local identity reset completed")
            return
        }
        autoSyncTask?.cancel()
        autoSyncTask = Task {
            while !Task.isCancelled {
                if networkMonitor.isConnected {
                    await syncNow(modelContext: modelContext)
                }
                do {
                    try await Task.sleep(for: .seconds(currentSyncInterval))
                } catch is CancellationError {
                    break
                } catch {
                    Self.logger.error(
                        "Auto-sync timer failed: \(error.localizedDescription)"
                    )
                    break
                }
            }
        }
    }

    /// Stops the periodic auto-sync loop.
    func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    /// Five minutes normally, doubling per consecutive sync failure up to the cap.
    private var currentSyncInterval: TimeInterval {
        guard consecutiveFailures > 0 else { return Self.baseSyncInterval }
        let exponent = Double(min(consecutiveFailures, 8))
        return min(Self.baseSyncInterval * pow(2, exponent), Self.maxSyncInterval)
    }

    // MARK: - Cleanup

    /// Restores crash-interrupted actions and removes only records known to be synced.
    /// Pending/retryable/permanent work is never discarded based on age.
    @discardableResult
    func prepareQueueForSync(modelContext: ModelContext) -> Bool {
        let actions: [OfflineAction]
        do {
            actions = try modelContext.fetch(FetchDescriptor<OfflineAction>())
        } catch {
            Self.logger.error("Could not inspect offline queue recovery state: \(error.localizedDescription)")
            return false
        }
        do {
            try saveAtomically(modelContext: modelContext) {
                for action in actions {
                    action.payloadByteCount = action.payloadByteCount
                        ?? action.payload.lengthOfBytes(using: .utf8)
                    switch action.status {
                    case .syncing, .inFlight:
                        // Claim recovery is not a failed server attempt.
                        action.status = .pending
                        action.nextAttemptAt = nil
                    case .directAttempt:
                        // A foreground transport may coexist with an auto-sync trigger.
                        // Only a process-local owner can keep this claim; after a crash
                        // or relaunch the set is empty and the exact replay is released.
                        if !liveDirectAttemptIDs.contains(action.id) {
                            action.status = .pending
                            action.nextAttemptAt = nil
                        }
                    case .failed:
                        action.status = action.retryCount >= Self.maxRetryCount
                            ? .permanent : .retryable
                        if action.status == .permanent {
                            action.nextAttemptAt = nil
                            action.lastError = action.lastError ?? "Legacy retry limit reached."
                        }
                    case .synced:
                        modelContext.delete(action)
                    case .pending, .retryable, .permanent:
                        break
                    }
                }
            }
            return true
        } catch {
            Self.logger.error("Could not persist offline queue recovery: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Pull Apply

    @discardableResult
    func applyPullRecords(_ records: [SyncPullRecord], modelContext: ModelContext) -> Bool {
        do {
            try SyncPullApplier.apply(records, modelContext: modelContext)
            return true
        } catch {
            Self.logger.error("Refused malformed sync pull page: \(error.localizedDescription)")
            return false
        }
    }

    private func decodePayload(_ json: String) -> [String: JSONValue]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}

/// Applies pulled records to a SwiftData context. Lives outside SyncManager so the
/// decode-and-upsert work can run on a background ModelContext off the main actor.
private enum SyncPullApplier {

    typealias SyncPullRecord = SyncManager.SyncPullRecord

    private static let logger = Logger(subsystem: "org.example.hausklar", category: "SyncManager")

    private enum PullApplyError: LocalizedError {
        case malformedMedicineRecord(table: String, recordId: String, field: String)
        case duplicateLocalRecord(table: String, recordId: String)

        var errorDescription: String? {
            switch self {
            case .malformedMedicineRecord(let table, let recordId, let field):
                return "Malformed \(table)/\(recordId): invalid or missing \(field)"
            case .duplicateLocalRecord(let table, let recordId):
                return "Duplicate local \(table) record ID: \(recordId)"
            }
        }
    }

    /// Existing models for only the tables present in a pull response.
    /// This turns a large first sync from one fetch per record into one fetch per table.
    private struct PullLookup {
        var calendarEvents: [String: CalendarEvent] = [:]
        var tasks: [String: FamilyTask] = [:]
        var medicineTypes: [String: MedicineType] = [:]
        var medicineDoses: [String: MedicineDose] = [:]
        var naps: [String: Nap] = [:]
        var dogActivities: [String: DogActivity] = [:]
        var birthdays: [String: Birthday] = [:]
        var meals: [String: Meal] = [:]
        var mealPlans: [String: MealPlan] = [:]
        var shoppingItems: [String: ShoppingItem] = [:]
        var healthRecords: [String: HealthRecord] = [:]
        var readingLogs: [String: ReadingLog] = [:]
        var spellingEntries: [String: SpellingEntry] = [:]
        var growthRecords: [String: GrowthRecord] = [:]
        var children: [String: Child] = [:]

        init(records: [SyncPullRecord], modelContext: ModelContext) throws {
            let idsByTable = Dictionary(grouping: records, by: \.tableName)
                .mapValues { $0.map(\.recordId) }

            if let ids = idsByTable["calendar_events"] {
                let descriptor = FetchDescriptor<CalendarEvent>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                calendarEvents = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "calendar_events"
                )
            }
            if let ids = idsByTable["tasks"] {
                let descriptor = FetchDescriptor<FamilyTask>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                tasks = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "tasks"
                )
            }
            if let ids = idsByTable["medicine_types"] {
                let descriptor = FetchDescriptor<MedicineType>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                medicineTypes = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "medicine_types"
                )
            }
            if let ids = idsByTable["medicine_doses"] {
                let descriptor = FetchDescriptor<MedicineDose>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                medicineDoses = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "medicine_doses"
                )
            }
            if let ids = idsByTable["naps"] {
                let descriptor = FetchDescriptor<Nap>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                naps = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "naps"
                )
            }
            if let ids = idsByTable["dog_activities"] {
                let descriptor = FetchDescriptor<DogActivity>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                dogActivities = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "dog_activities"
                )
            }
            if let ids = idsByTable["birthdays"] {
                let descriptor = FetchDescriptor<Birthday>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                birthdays = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "birthdays"
                )
            }
            if let ids = idsByTable["meals"] {
                let descriptor = FetchDescriptor<Meal>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                meals = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "meals"
                )
            }
            if let ids = idsByTable["meal_plans"] {
                let descriptor = FetchDescriptor<MealPlan>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                mealPlans = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "meal_plans"
                )
            }
            if let ids = idsByTable["shopping_items"] {
                let descriptor = FetchDescriptor<ShoppingItem>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                shoppingItems = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "shopping_items"
                )
            }
            if let ids = idsByTable["health_data"] {
                let descriptor = FetchDescriptor<HealthRecord>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                healthRecords = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "health_data"
                )
            }
            if let ids = idsByTable["homework_reading"] {
                let descriptor = FetchDescriptor<ReadingLog>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                readingLogs = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "homework_reading"
                )
            }
            if let ids = idsByTable["homework_spellings"] {
                let descriptor = FetchDescriptor<SpellingEntry>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                spellingEntries = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "homework_spellings"
                )
            }
            if let ids = idsByTable["growth_records"] {
                let descriptor = FetchDescriptor<GrowthRecord>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                growthRecords = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "growth_records"
                )
            }
            if let ids = idsByTable["children"] {
                let descriptor = FetchDescriptor<Child>(
                    predicate: #Predicate { ids.contains($0.id) }
                )
                children = try Self.index(
                    modelContext.fetch(descriptor), id: \.id, table: "children"
                )
            }
        }

        private static func index<T>(
            _ models: [T],
            id: KeyPath<T, String>,
            table: String
        ) throws -> [String: T] {
            var indexed: [String: T] = [:]
            indexed.reserveCapacity(models.count)
            for model in models {
                let recordId = model[keyPath: id]
                guard indexed.updateValue(model, forKey: recordId) == nil else {
                    throw PullApplyError.duplicateLocalRecord(
                        table: table,
                        recordId: recordId
                    )
                }
            }
            return indexed
        }
    }

    static func apply(_ records: [SyncPullRecord], modelContext: ModelContext) throws {
        // Validate the entire safety-critical subset before touching the context.
        // A malformed record therefore rejects the page atomically and leaves the
        // durable cursor unchanged for a later replay.
        try records.forEach(validateMedicineRecord)
        var lookup = try PullLookup(records: records, modelContext: modelContext)
        for record in records {
            try applyPullRecord(record, modelContext: modelContext, lookup: &lookup)
        }
    }

    private static func applyPullRecord(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) throws {
        // Handle explicit delete operations from the server
        if record.operation == "delete" {
            applyDeleteRecord(record, lookup: &lookup)
            return
        }

        // Handle soft-delete: if the record data contains a non-nil deletedAt,
        // the upsert methods will set it on the local model (they already assign deletedAt).
        // This works for all entity types via the existing upsert logic.

        switch record.tableName {
        case "calendar_events":
            upsertCalendarEvent(record, modelContext: modelContext, lookup: &lookup)
        case "tasks":
            upsertTask(record, modelContext: modelContext, lookup: &lookup)
        case "medicine_types":
            try upsertMedicineType(record, modelContext: modelContext, lookup: &lookup)
        case "medicine_doses":
            try upsertMedicineDose(record, modelContext: modelContext, lookup: &lookup)
        case "naps":
            upsertNap(record, modelContext: modelContext, lookup: &lookup)
        case "dog_activities":
            upsertDogActivity(record, modelContext: modelContext, lookup: &lookup)
        case "birthdays":
            upsertBirthday(record, modelContext: modelContext, lookup: &lookup)
        case "meals":
            upsertMeal(record, modelContext: modelContext, lookup: &lookup)
        case "meal_plans":
            upsertMealPlan(record, modelContext: modelContext, lookup: &lookup)
        case "shopping_items":
            upsertShoppingItem(record, modelContext: modelContext, lookup: &lookup)
        case "health_data":
            upsertHealthRecord(record, modelContext: modelContext, lookup: &lookup)
        case "homework_reading":
            upsertReadingLog(record, modelContext: modelContext, lookup: &lookup)
        case "homework_spellings":
            upsertSpellingEntry(record, modelContext: modelContext, lookup: &lookup)
        case "growth_records":
            upsertGrowthRecord(record, modelContext: modelContext, lookup: &lookup)
        case "children":
            upsertChild(record, modelContext: modelContext, lookup: &lookup)
        default:
            Self.logger.warning("Unknown table name in pull: \(record.tableName)")
        }
    }

    /// Handles explicit "delete" operations from the server by soft-deleting the local record.
    private static func applyDeleteRecord(_ record: SyncPullRecord, lookup: inout PullLookup) {
        // Parse the deletedAt timestamp from the server, falling back to now
        let deletedAt: Date = {
            if let str = record.data?["deleted_at"]?.stringValue {
                return ISODateParser.parse(str) ?? Date()
            }
            return Date()
        }()
        let id = record.recordId

        switch record.tableName {
        case "calendar_events":
            lookup.calendarEvents[id]?.deletedAt = deletedAt
        case "tasks":
            lookup.tasks[id]?.deletedAt = deletedAt
        case "medicine_types":
            lookup.medicineTypes[id]?.deletedAt = deletedAt
        case "medicine_doses":
            lookup.medicineDoses[id]?.deletedAt = deletedAt
        case "naps":
            lookup.naps[id]?.deletedAt = deletedAt
        case "dog_activities":
            lookup.dogActivities[id]?.deletedAt = deletedAt
        case "birthdays":
            lookup.birthdays[id]?.deletedAt = deletedAt
        case "meals":
            lookup.meals[id]?.deletedAt = deletedAt
        case "meal_plans":
            lookup.mealPlans[id]?.deletedAt = deletedAt
        case "shopping_items":
            lookup.shoppingItems[id]?.deletedAt = deletedAt
        case "health_data":
            lookup.healthRecords[id]?.deletedAt = deletedAt
        case "homework_reading":
            lookup.readingLogs[id]?.deletedAt = deletedAt
        case "homework_spellings":
            lookup.spellingEntries[id]?.deletedAt = deletedAt
        case "growth_records":
            lookup.growthRecords[id]?.deletedAt = deletedAt
        case "children":
            lookup.children[id]?.deletedAt = deletedAt
        default:
            Self.logger.warning("Unknown table name in delete: \(record.tableName)")
        }
    }

    /// Parse an ISO 8601 date string from sync data, returning nil if unparseable.
    private static func parseDate(_ data: [String: JSONValue], key: String) -> Date? {
        guard let str = data[key]?.stringValue else { return nil }
        return ISODateParser.parse(str)
    }

    private static func validateMedicineRecord(_ record: SyncPullRecord) throws {
        guard record.tableName == "medicine_types" || record.tableName == "medicine_doses" else {
            return
        }
        guard !record.recordId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PullApplyError.malformedMedicineRecord(
                table: record.tableName,
                recordId: record.recordId,
                field: "record_id"
            )
        }
        guard ["create", "update", "delete"].contains(record.operation) else {
            throw PullApplyError.malformedMedicineRecord(
                table: record.tableName,
                recordId: record.recordId,
                field: "operation"
            )
        }
        guard record.operation != "delete" else { return }
        guard let data = record.data else {
            throw PullApplyError.malformedMedicineRecord(
                table: record.tableName,
                recordId: record.recordId,
                field: "data"
            )
        }

        _ = try requiredDate("created_at", in: data, for: record)
        _ = try requiredDate("updated_at", in: data, for: record)

        if record.tableName == "medicine_types" {
            _ = try requiredString("name", in: data, for: record)
            _ = try requiredString("child_id", in: data, for: record)
            guard let minimumHours = data["min_hours_between_doses"]?.doubleValue,
                  minimumHours.isFinite,
                  (0.25...168).contains(minimumHours) else {
                throw malformed(record, field: "min_hours_between_doses")
            }
            guard let maximumDoses = data["max_doses_24h"]?.intValue,
                  (1...24).contains(maximumDoses) else {
                throw malformed(record, field: "max_doses_24h")
            }
            return
        }

        _ = try requiredString("child_id", in: data, for: record)
        _ = try requiredDate("given_at", in: data, for: record)
        _ = try requiredString("given_by", in: data, for: record)
        let typeId = data["medicine_type_id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let medicineName = data["medicine_name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard typeId?.isEmpty == false || medicineName?.isEmpty == false else {
            throw malformed(record, field: "medicine_type_id/medicine_name")
        }
    }

    private static func requiredString(
        _ key: String,
        in data: [String: JSONValue],
        for record: SyncPullRecord
    ) throws -> String {
        guard let value = data[key]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw malformed(record, field: key)
        }
        return value
    }

    private static func requiredDate(
        _ key: String,
        in data: [String: JSONValue],
        for record: SyncPullRecord
    ) throws -> Date {
        let value = try requiredString(key, in: data, for: record)
        guard let date = ISODateParser.parse(value) else {
            throw malformed(record, field: key)
        }
        return date
    }

    private static func malformed(
        _ record: SyncPullRecord,
        field: String
    ) -> PullApplyError {
        .malformedMedicineRecord(
            table: record.tableName,
            recordId: record.recordId,
            field: field
        )
    }

    // MARK: - Upsert Methods

    private static func upsertCalendarEvent(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateCalendarEvent(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.title = data["title"]?.stringValue ?? item.title
        item.eventDescription = data["description"]?.stringValue
        if let d = parseDate(data, key: "start_time") { item.startTime = d }
        if let d = parseDate(data, key: "end_time") { item.endTime = d }
        item.allDay = data["all_day"]?.boolValue ?? item.allDay
        item.recurrenceRule = data["recurrence_rule"]?.stringValue
        item.location = data["location"]?.stringValue
        item.familyMemberIds = data["family_member_ids"]?.stringValue
        item.assignedTo = data["assigned_to"]?.stringValue
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertTask(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateTask(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.title = data["title"]?.stringValue ?? item.title
        item.taskDescription = data["description"]?.stringValue
        item.assignedTo = data["assigned_to"]?.stringValue
        item.dueDate = parseDate(data, key: "due_date")
        item.completedAt = parseDate(data, key: "completed_at")
        item.category = data["category"]?.stringValue
        item.recurrenceRule = data["recurrence_rule"]?.stringValue
        item.priority = data["priority"]?.intValue ?? item.priority
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertMedicineType(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) throws {
        guard let data = record.data else { throw malformed(record, field: "data") }
        let name = try requiredString("name", in: data, for: record)
        let childId = try requiredString("child_id", in: data, for: record)
        guard let minimumHours = data["min_hours_between_doses"]?.doubleValue,
              let maximumDoses = data["max_doses_24h"]?.intValue else {
            throw malformed(record, field: "dose limits")
        }
        let createdAt = try requiredDate("created_at", in: data, for: record)
        let updatedAt = try requiredDate("updated_at", in: data, for: record)
        let item = fetchOrCreateMedicineType(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.name = name
        item.minHoursBetweenDoses = minimumHours
        item.maxDoses24h = maximumDoses
        item.notes = data["notes"]?.stringValue
        item.color = data["color"]?.stringValue
        item.defaultDoseAmount = data["default_dose_amount"]?.stringValue
        item.childId = childId
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertMedicineDose(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) throws {
        guard let data = record.data else { throw malformed(record, field: "data") }
        let childId = try requiredString("child_id", in: data, for: record)
        let givenAt = try requiredDate("given_at", in: data, for: record)
        let givenBy = try requiredString("given_by", in: data, for: record)
        let createdAt = try requiredDate("created_at", in: data, for: record)
        let updatedAt = try requiredDate("updated_at", in: data, for: record)
        let medicineTypeId = data["medicine_type_id"]?.stringValue ?? ""
        let item: MedicineDose
        if let existing = lookup.medicineDoses[record.recordId] {
            item = existing
        } else {
            item = MedicineDose(
                id: record.recordId,
                medicineTypeId: medicineTypeId,
                childId: childId,
                givenAt: givenAt
            )
            modelContext.insert(item)
            lookup.medicineDoses[record.recordId] = item
        }
        item.medicineTypeId = medicineTypeId
        item.childId = childId
        item.givenAt = givenAt
        item.givenBy = givenBy
        item.doseAmount = data["dose_amount"]?.stringValue
        item.medicineName = data["medicine_name"]?.stringValue
        item.notes = data["notes"]?.stringValue
        item.createdAt = createdAt
        item.updatedAt = updatedAt
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertNap(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateNap(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.childId = data["child_id"]?.stringValue ?? item.childId
        if let d = parseDate(data, key: "started_at") { item.startedAt = d }
        item.endedAt = parseDate(data, key: "ended_at")
        item.location = data["location"]?.stringValue
        item.notes = data["notes"]?.stringValue
        item.sleepType = data["sleep_type"]?.stringValue ?? item.sleepType
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertDogActivity(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateDogActivity(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.activityType = data["activity_type"]?.stringValue ?? item.activityType
        if let d = parseDate(data, key: "started_at") { item.startedAt = d }
        item.endedAt = parseDate(data, key: "ended_at")
        item.notes = data["notes"]?.stringValue
        item.doneBy = data["done_by"]?.stringValue
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertBirthday(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateBirthday(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.personName = data["person_name"]?.stringValue ?? item.personName
        if let d = parseDate(data, key: "date_of_birth") { item.dateOfBirth = d }
        item.relationship = data["relationship"]?.stringValue
        item.reminderDaysBefore = data["reminder_days_before"]?.intValue ?? item.reminderDaysBefore
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertMeal(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateMeal(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.name = data["name"]?.stringValue ?? item.name
        item.mealDescription = data["description"]?.stringValue
        item.recipeURL = data["recipe_url"]?.stringValue
        item.tags = data["tags"]?.stringValue
        item.ingredients = data["ingredients"]?.stringValue
        item.lastMadeAt = parseDate(data, key: "last_made_at")
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertMealPlan(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateMealPlan(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.mealId = data["meal_id"]?.stringValue ?? item.mealId
        if let d = parseDate(data, key: "date") { item.date = d }
        item.mealType = data["meal_type"]?.stringValue ?? item.mealType
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertShoppingItem(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateShoppingItem(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.name = data["name"]?.stringValue ?? item.name
        item.quantity = data["quantity"]?.stringValue
        item.category = data["category"]?.stringValue
        item.mealPlanId = data["meal_plan_id"]?.stringValue
        item.checked = data["checked"]?.boolValue ?? item.checked
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertHealthRecord(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateHealthRecord(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.source = data["source"]?.stringValue ?? item.source
        item.dataType = data["data_type"]?.stringValue ?? item.dataType
        item.value = data["value"]?.doubleValue ?? item.value
        item.unit = data["unit"]?.stringValue ?? item.unit
        if let d = parseDate(data, key: "recorded_at") { item.recordedAt = d }
        item.metadata = data["metadata"]?.stringValue
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertReadingLog(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateReadingLog(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.childId = data["child_id"]?.stringValue ?? item.childId
        item.bookTitle = data["book_title"]?.stringValue ?? item.bookTitle
        item.minutes = data["minutes"]?.intValue ?? item.minutes
        if let d = parseDate(data, key: "date") { item.date = d }
        item.notes = data["notes"]?.stringValue
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertSpellingEntry(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateSpellingEntry(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.childId = data["child_id"]?.stringValue ?? item.childId
        item.wordList = data["word_list"]?.stringValue ?? item.wordList
        item.testDate = parseDate(data, key: "test_date")
        item.score = data["score"]?.intValue
        item.practiceCount = data["practice_count"]?.intValue ?? item.practiceCount
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertGrowthRecord(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateGrowthRecord(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.childId = data["child_id"]?.stringValue ?? item.childId
        if let d = parseDate(data, key: "date") { item.date = d }
        item.heightCm = data["height_cm"]?.doubleValue
        item.weightKg = data["weight_kg"]?.doubleValue
        item.headCircumferenceCm = data["head_circumference_cm"]?.doubleValue
        item.notes = data["notes"]?.stringValue
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    private static func upsertChild(
        _ record: SyncPullRecord,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) {
        guard let data = record.data else { return }
        let item = fetchOrCreateChild(
            id: record.recordId, modelContext: modelContext, lookup: &lookup
        )
        item.name = data["name"]?.stringValue ?? item.name
        if let d = parseDate(data, key: "date_of_birth") { item.dateOfBirth = d }
        item.notes = data["notes"]?.stringValue
        if let d = parseDate(data, key: "created_at") { item.createdAt = d }
        if let d = parseDate(data, key: "updated_at") { item.updatedAt = d }
        item.createdBy = data["created_by"]?.stringValue
        item.deletedAt = parseDate(data, key: "deleted_at")
    }

    // MARK: - Lookup Helpers

    private static func fetchOrCreateCalendarEvent(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> CalendarEvent {
        if let existing = lookup.calendarEvents[id] { return existing }
        let item = CalendarEvent(id: id)
        modelContext.insert(item)
        lookup.calendarEvents[id] = item
        return item
    }

    private static func fetchOrCreateTask(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> FamilyTask {
        if let existing = lookup.tasks[id] { return existing }
        let item = FamilyTask(id: id)
        modelContext.insert(item)
        lookup.tasks[id] = item
        return item
    }

    private static func fetchOrCreateMedicineType(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> MedicineType {
        if let existing = lookup.medicineTypes[id] { return existing }
        let item = MedicineType(id: id)
        modelContext.insert(item)
        lookup.medicineTypes[id] = item
        return item
    }

    private static func fetchOrCreateNap(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> Nap {
        if let existing = lookup.naps[id] { return existing }
        let item = Nap(id: id)
        modelContext.insert(item)
        lookup.naps[id] = item
        return item
    }

    private static func fetchOrCreateDogActivity(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> DogActivity {
        if let existing = lookup.dogActivities[id] { return existing }
        let item = DogActivity(id: id)
        modelContext.insert(item)
        lookup.dogActivities[id] = item
        return item
    }

    private static func fetchOrCreateBirthday(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> Birthday {
        if let existing = lookup.birthdays[id] { return existing }
        let item = Birthday(id: id)
        modelContext.insert(item)
        lookup.birthdays[id] = item
        return item
    }

    private static func fetchOrCreateMeal(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> Meal {
        if let existing = lookup.meals[id] { return existing }
        let item = Meal(id: id)
        modelContext.insert(item)
        lookup.meals[id] = item
        return item
    }

    private static func fetchOrCreateMealPlan(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> MealPlan {
        if let existing = lookup.mealPlans[id] { return existing }
        let item = MealPlan(id: id)
        modelContext.insert(item)
        lookup.mealPlans[id] = item
        return item
    }

    private static func fetchOrCreateShoppingItem(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> ShoppingItem {
        if let existing = lookup.shoppingItems[id] { return existing }
        let item = ShoppingItem(id: id)
        modelContext.insert(item)
        lookup.shoppingItems[id] = item
        return item
    }

    private static func fetchOrCreateHealthRecord(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> HealthRecord {
        if let existing = lookup.healthRecords[id] { return existing }
        let item = HealthRecord(id: id)
        modelContext.insert(item)
        lookup.healthRecords[id] = item
        return item
    }

    private static func fetchOrCreateReadingLog(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> ReadingLog {
        if let existing = lookup.readingLogs[id] { return existing }
        let item = ReadingLog(id: id)
        modelContext.insert(item)
        lookup.readingLogs[id] = item
        return item
    }

    private static func fetchOrCreateSpellingEntry(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> SpellingEntry {
        if let existing = lookup.spellingEntries[id] { return existing }
        let item = SpellingEntry(id: id)
        modelContext.insert(item)
        lookup.spellingEntries[id] = item
        return item
    }

    private static func fetchOrCreateGrowthRecord(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> GrowthRecord {
        if let existing = lookup.growthRecords[id] { return existing }
        let item = GrowthRecord(id: id)
        modelContext.insert(item)
        lookup.growthRecords[id] = item
        return item
    }

    private static func fetchOrCreateChild(
        id: String,
        modelContext: ModelContext,
        lookup: inout PullLookup
    ) -> Child {
        if let existing = lookup.children[id] { return existing }
        let item = Child(id: id)
        modelContext.insert(item)
        lookup.children[id] = item
        return item
    }
}
