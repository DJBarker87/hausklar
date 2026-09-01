import CryptoKit
import Foundation
import os

/// A generic REST API client that handles authentication, token refresh, and JSON coding.
/// `APIClient` is intentionally usable from feature actors and main-actor view
/// models. Every mutable field is either immutable after initialization or
/// serialized by one of the locks below; JSON coding is also serialized because
/// Foundation's encoder and decoder are mutable reference types.
final class APIClient: @unchecked Sendable {

    enum MultipartUploadSourceError: LocalizedError, Equatable, Sendable {
        case invalidFile
        case fileChanged
        case tooManyFiles(maximum: Int)
        case fieldsTooLarge(maximumBytes: Int)
        case requestTooLarge(maximumBytes: Int)

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return "A selected upload file is no longer available. Please select it again."
            case .fileChanged:
                return "A selected upload file changed while it was being prepared. Please try again."
            case .tooManyFiles(let maximum):
                return "Upload at most \(maximum) files at once."
            case .fieldsTooLarge(let maximumBytes):
                return "The upload details exceed the \(maximumBytes / 1_024) KB limit."
            case .requestTooLarge(let maximumBytes):
                return "The selected files exceed the \(maximumBytes / (1_024 * 1_024)) MB upload limit."
            }
        }
    }

    enum MultipartOfflineReplayPolicy: Equatable, Sendable {
        /// APIClient owns a protected durable body copy and generic retry state.
        case genericQueue
        /// A feature-specific stable-ID queue owns replay and acknowledgement.
        case callerManaged
    }

    enum GetCachePolicy: Equatable, Sendable {
        /// Return a fresh cached value first, otherwise use the network and retain
        /// the existing offline stale fallback.
        case cacheFirst
        /// Always try the network first, but retain the existing offline fallback.
        case networkThenStale
        /// Use only a live response. Never read, write, or fall back to FileCache.
        case networkOnly
    }

    /// A caller-owned contract for authenticated binary responses. Keeping the
    /// byte boundary and accepted media types in one hashable value also makes
    /// it impossible for an in-flight request with a looser policy to satisfy a
    /// stricter waiter.
    struct DownloadDataPolicy: Hashable, Sendable {
        let maximumBytes: Int
        let allowedMediaTypes: Set<String>
        fileprivate let imageLimits: BoundedHTTPPayload.ImageLimits?

        init(
            maximumBytes: Int,
            allowedMediaTypes: Set<String>,
            imageLimits: BoundedHTTPPayload.ImageLimits? = nil
        ) {
            self.maximumBytes = maximumBytes
            self.allowedMediaTypes = Set(
                allowedMediaTypes.compactMap(BoundedHTTPPayload.normalizedMediaType)
            )
            self.imageLimits = imageLimits
        }

        static func image(
            maximumBytes: Int,
            maximumDimension: Int = 8_192,
            maximumPixels: Int64 = 50_000_000
        ) -> Self {
            Self(
                maximumBytes: maximumBytes,
                allowedMediaTypes: ["image/jpeg", "image/png", "image/webp"],
                imageLimits: BoundedHTTPPayload.ImageLimits(
                    maximumWidth: maximumDimension,
                    maximumHeight: maximumDimension,
                    maximumPixels: maximumPixels
                )
            )
        }

        fileprivate var inflightSuffix: String {
            let dimensions = imageLimits.map {
                "\($0.maximumWidth)x\($0.maximumHeight)x\($0.maximumPixels)"
            } ?? "opaque"
            let mediaTypes = allowedMediaTypes.sorted().map {
                "\($0.utf8.count):\($0)"
            }.joined(separator: "|")
            return "#binary=\(maximumBytes):\(mediaTypes):\(dimensions)"
        }
    }

    enum GetProvenance: Equatable {
        case network
        case freshCache
        case staleFallback
    }

    struct ProvenancedGet<Value> {
        let value: Value
        let provenance: GetProvenance
    }

    /// One logical authenticated session. Token rotation keeps the same generation;
    /// clearing or installing a login always creates a new one.
    struct SessionSnapshot: Equatable, Sendable {
        let identity: String
        let generation: UInt64
        let accessToken: String
        let refreshToken: String

        fileprivate var key: SessionKey {
            SessionKey(identity: identity, generation: generation)
        }
    }

    fileprivate struct SessionKey: Equatable, Sendable {
        let identity: String
        let generation: UInt64
    }

    /// Immutable authority captured synchronously with a request, before the
    /// first actor suspension. Cache scope and all later validation use this one
    /// lease instead of consulting mutable global identity state independently.
    private struct RequestSessionLease: Sendable {
        let session: SessionSnapshot?

        var cacheScope: String? { session?.identity }
        var key: SessionKey? { session?.key }
    }

    // MARK: - Singleton

    static let shared = APIClient()

    private static let logger = Logger(subsystem: "org.example.hausklar", category: "APIClient")
    static let sessionGenerationHeader = "X-HausKlar-Session-Generation"
    /// Ordinary API models are deliberately finite. URLSession receives these
    /// bodies as temporary files, so chunked responses cannot grow the app heap;
    /// only a validated response of at most 16 MiB is copied for JSON decoding.
    static let maximumJSONResponseBytes = 16 * 1_024 * 1_024
    private static let maximumErrorResponseBytes = 64 * 1_024
    /// Leaves headroom beneath the server's default 80 MB media-request limit
    /// for multipart boundaries, filenames, and repeated metadata fields.
    static let maximumFileBackedMultipartSourceBytes = 75 * 1_024 * 1_024

    // MARK: - Configuration

    let defaultBaseURL: String

    var baseURL: String {
        get { stateLock.withLock { cachedBaseURL } }
        set { stateLock.withLock { cachedBaseURL = newValue } }
    }

    /// Current in-memory access token. Durable state lives only in the atomic
    /// `StoredSessionEnvelope` managed by AppState/token rotation.
    var accessToken: String? {
        get { stateLock.withLock { cachedAccessToken } }
        set {
            let refresh = stateLock.withLock { () -> Task<Void, Error>? in
                guard newValue != cachedAccessToken else { return nil }
                let task = invalidateCredentialGenerationLocked()
                cachedAccessToken = newValue
                return task
            }
            refresh?.cancel()
        }
    }

    /// Current in-memory refresh token. Never persisted as an independent item.
    var refreshToken: String? {
        get { stateLock.withLock { cachedRefreshToken } }
        set {
            let refresh = stateLock.withLock { () -> Task<Void, Error>? in
                guard newValue != cachedRefreshToken else { return nil }
                let task = invalidateCredentialGenerationLocked()
                cachedRefreshToken = newValue
                return task
            }
            refresh?.cancel()
        }
    }

    /// Stable cache namespace for the signed-in family member; unlike access tokens, it survives rotation.
    var cacheIdentity: String? {
        get { stateLock.withLock { cachedCacheIdentity } }
        set {
            let refresh = stateLock.withLock { () -> Task<Void, Error>? in
                guard cachedCacheIdentity != newValue else { return nil }
                let task = invalidateCredentialGenerationLocked()
                cachedCacheIdentity = newValue
                return task
            }
            refresh?.cancel()
        }
    }

    // MARK: - Private

    private let session: URLSession
    private let transportDelegate = BoundedURLSessionTransportDelegate()
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let codingLock = NSLock()
    let transferTemporaryRoot: URL
    private var refreshTask: Task<Void, Error>?
    private var refreshTaskSession: SessionKey?
    private var credentialGeneration: UInt64 = 0
    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedCacheIdentity: String?
    private var cachedBaseURL: String
    private var requiresPersistedTokenRotation = false
    private let loadSessionEnvelope: @Sendable () throws -> StoredSessionEnvelope?
    private let saveSessionEnvelope: @Sendable (StoredSessionEnvelope) throws -> Void
    private let offlineMutationStore: OfflineHTTPMutationStore
    private let resolveClientId: @Sendable () throws -> String
    private var resolvedClientId: String?
    private var cachedOnAuthFailure: (@MainActor @Sendable (SessionSnapshot) -> Void)?
    private var cachedOnMutationCommitted: (@Sendable () -> Void)?
    private var cachedCacheReadBarrierForTesting: (@Sendable () async -> Void)?
    private var cachedTransferReadyBarrierForTesting: (@Sendable () async -> Void)?
    private let stateLock = NSLock()
    private let clientIdentityLock = NSLock()
    private let inflightLock = NSLock()
    private static let operationIDHeader = "X-HausKlar-Operation-ID"

    private final class InflightRequest {
        let task: Task<Data, Error>
        var waiterIDs: Set<UUID>
        var cacheWriteClaimed = false

        init(task: Task<Data, Error>, firstWaiterID: UUID) {
            self.task = task
            waiterIDs = [firstWaiterID]
        }
    }

    private struct InflightLease {
        let task: Task<Data, Error>
        let waiterID: UUID
        let isFirstWaiter: Bool
    }

    private struct DataTransportResponse: Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    /// Foundation's HTTP response reference is immutable after delivery; all
    /// other fields are Sendable values and the temporary path remains owned by
    /// the receiving APIClient operation.
    private struct DownloadTransportResponse: @unchecked Sendable {
        let temporaryURL: URL
        let temporaryDirectory: URL
        let errorData: Data?
        let response: HTTPURLResponse
    }

    /// In-flight GET request deduplication map. Waiters are tracked so a view
    /// cancellation only stops transport when no other visible consumer needs it.
    private var inflightRequests: [String: InflightRequest] = [:]
    private var inflightDataTransfers: [UUID: Task<DataTransportResponse, Error>] = [:]
    private var inflightUploads: [UUID: Task<DataTransportResponse, Error>] = [:]
    private var inflightDownloads: [UUID: Task<DownloadTransportResponse, Error>] = [:]
    private var offlineMutationFlushTask: Task<Void, Never>?
    private var offlineMutationFlushID: UUID?

    init(
        sessionConfiguration: URLSessionConfiguration = .default,
        loadSessionEnvelope: @escaping @Sendable () throws -> StoredSessionEnvelope? = {
            try KeychainManager.loadSessionEnvelope()
        },
        saveSessionEnvelope: @escaping @Sendable (StoredSessionEnvelope) throws -> Void = {
            try KeychainManager.saveSessionEnvelope($0)
        },
        resolveClientId: @escaping @Sendable () throws -> String = {
            try KeychainManager.getOrCreateClientId()
        },
        transferTemporaryRoot: URL? = nil,
        offlineMutationStore: OfflineHTTPMutationStore = .shared
    ) {
        let configuredDefaultBaseURL: String
        if let configuredBaseURL = Bundle.main.object(
            forInfoDictionaryKey: "APIBaseURL"
        ) as? String,
           !configuredBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuredDefaultBaseURL = configuredBaseURL
        } else {
            configuredDefaultBaseURL = "http://localhost:8001/api"
        }
        defaultBaseURL = configuredDefaultBaseURL
        cachedBaseURL = configuredDefaultBaseURL
        self.loadSessionEnvelope = loadSessionEnvelope
        self.saveSessionEnvelope = saveSessionEnvelope
        self.resolveClientId = resolveClientId
        self.offlineMutationStore = offlineMutationStore
        self.transferTemporaryRoot = transferTemporaryRoot
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("HausKlarTransfers", isDirectory: true)
        KeychainManager.migrateStoredItemProtection()

        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        // HausKlar's identity-scoped FileCache owns offline semantics. Avoid a
        // second opaque URLCache copy of authenticated family data.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        config.httpAdditionalHeaders = ["User-Agent": "HausKlar/\(version) iOS"]
        session = URLSession(configuration: config, delegate: transportDelegate, delegateQueue: nil)
        // Transfer operations create the protected root through throwing code.
        // Startup only reconciles a root left by an earlier process.
        Self.reconcileInterruptedTransfers(at: self.transferTemporaryRoot)

        // Ensure legacy custom URL overrides are ignored and removed.
        UserDefaults.standard.removeObject(forKey: "api.customBaseURL")
        // Clean up any legacy UserDefaults cache entries
        Self.cleanLegacyUserDefaultsCache()
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
    }

    /// The verified install-scoped UUID. Access is intentionally throwing so
    /// no caller can mistake an unavailable Keychain value for a usable ID.
    var clientId: String {
        get throws { try requireClientId() }
    }

    /// Resolves lazily and caches only a value that has passed Keychain's
    /// write/read-back contract. A transient Keychain failure is retried on the
    /// next explicit mutation/session activation attempt.
    @discardableResult
    func requireClientId() throws -> String {
        try clientIdentityLock.withLock {
            if let resolvedClientId { return resolvedClientId }
            do {
                let candidate = try resolveClientId()
                guard UUID(uuidString: candidate) != nil else {
                    throw ClientIdentityError.malformedStoredIdentifier
                }
                resolvedClientId = candidate
                return candidate
            } catch {
                Self.logger.error(
                    "Secure client identity is unavailable: \(error.localizedDescription)"
                )
                throw ClientIdentityError.unavailable
            }
        }
    }

    private var availableClientId: String? {
        clientIdentityLock.withLock { resolvedClientId }
    }

    /// Reclaims crash leftovers from the transfer root without touching fresh
    /// work or any path that is not an exact, non-symlinked HausKlar layout.
    @discardableResult
    static func reconcileInterruptedTransfers(
        at root: URL,
        fileManager: FileManager = .default,
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        maximumCandidates: Int = 256,
        maximumRemovals: Int = 32
    ) -> Int {
        guard maximumCandidates > 0, maximumRemovals > 0 else { return 0 }
        let standardizedRoot = root.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        guard fileManager.fileExists(atPath: standardizedRoot.path) else { return 0 }
        let rootValues: URLResourceValues
        do {
            rootValues = try standardizedRoot.resourceValues(forKeys: keys)
        } catch {
            logger.error(
                "Transfer reconciliation could not inspect its root: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries the root inspection."
            )
            return 0
        }
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            logger.error(
                "Transfer reconciliation rejected an invalid root. Reconciliation: a later transfer fails closed while preparing the protected root."
            )
            return 0
        }
        guard let entries = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { _, error in
                logger.error(
                    "Transfer reconciliation enumeration failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries bounded enumeration."
                )
                return false
            }
        ) else {
            logger.error(
                "Transfer reconciliation could not create an enumerator. Reconciliation: the next API client initialization retries bounded enumeration."
            )
            return 0
        }

        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        var removed = 0
        var inspected = 0
        while inspected < maximumCandidates,
              removed < maximumRemovals,
              let entry = entries.nextObject() as? URL {
            inspected += 1
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == standardizedRoot,
                  let kind = interruptedTransferKind(candidate.lastPathComponent) else { continue }
            let directoryValues: URLResourceValues
            do {
                directoryValues = try candidate.resourceValues(forKeys: keys)
            } catch {
                logger.error(
                    "Transfer reconciliation could not inspect a candidate: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries the candidate."
                )
                continue
            }
            guard
                  directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true,
                  let directoryDate = directoryValues.contentModificationDate
                    ?? directoryValues.creationDate,
                  directoryDate <= cutoff else { continue }
            var childEnumerationFailed = false
            guard let childEnumerator = fileManager.enumerator(
                at: candidate,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                errorHandler: { _, error in
                    childEnumerationFailed = true
                    logger.error(
                        "Transfer payload enumeration failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries the candidate."
                    )
                    return false
                }
            ) else {
                logger.error(
                    "Transfer reconciliation could not inspect a candidate payload. Reconciliation: the next API client initialization retries the candidate."
                )
                continue
            }
            var children: [URL] = []
            while children.count < 2,
                  let child = childEnumerator.nextObject() as? URL {
                children.append(child)
            }
            guard !childEnumerationFailed else { continue }
            guard children.count <= 1 else { continue }

            if let payload = children.first {
                let file = payload.standardizedFileURL
                let nameIsValid = kind == "multipart"
                    ? file.lastPathComponent == "request.body"
                    : !file.lastPathComponent.isEmpty && !file.lastPathComponent.hasPrefix(".")
                guard nameIsValid, file.deletingLastPathComponent() == candidate else { continue }
                let values: URLResourceValues
                do {
                    values = try file.resourceValues(forKeys: keys)
                } catch {
                    logger.error(
                        "Transfer reconciliation could not inspect a payload: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries the candidate."
                    )
                    continue
                }
                guard
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let payloadDate = values.contentModificationDate ?? values.creationDate,
                      payloadDate <= cutoff else { continue }
            }
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                logger.error(
                    "Interrupted transfer cleanup failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries aged transfer cleanup."
                )
                continue
            }
        }
        return removed
    }

    private static func interruptedTransferKind(_ filename: String) -> String? {
        for kind in ["multipart", "download"] {
            let prefix = "\(kind)-"
            guard filename.hasPrefix(prefix) else { continue }
            let suffix = String(filename.dropFirst(prefix.count))
            guard suffix.count == 36, UUID(uuidString: suffix) != nil else { return nil }
            return kind
        }
        return nil
    }

    /// Called on the main actor when token refresh fails. Wire this up to force
    /// a logout. Access is locked because tests and app lifecycle wiring may
    /// replace the callback while transport work is active.
    var onAuthFailure: (@MainActor @Sendable (SessionSnapshot) -> Void)? {
        get { stateLock.withLock { cachedOnAuthFailure } }
        set { stateLock.withLock { cachedOnAuthFailure = newValue } }
    }

    /// Called after every successful mutation (POST/PUT/PATCH/DELETE).
    /// Wired up to refresh widget timelines.
    var onMutationCommitted: (@Sendable () -> Void)? {
        get { stateLock.withLock { cachedOnMutationCommitted } }
        set { stateLock.withLock { cachedOnMutationCommitted = newValue } }
    }

    /// Deterministic suspension seam for account-switch cache tests. Nil in
    /// production; it deliberately runs after cache I/O and before lease checks.
    var cacheReadBarrierForTesting: (@Sendable () async -> Void)? {
        get { stateLock.withLock { cachedCacheReadBarrierForTesting } }
        set { stateLock.withLock { cachedCacheReadBarrierForTesting = newValue } }
    }

    /// Test-only seam after a protected multipart body is fully staged and
    /// before transport. It makes cancellation/account replacement races
    /// deterministic without changing production scheduling.
    var transferReadyBarrierForTesting: (@Sendable () async -> Void)? {
        get { stateLock.withLock { cachedTransferReadyBarrierForTesting } }
        set { stateLock.withLock { cachedTransferReadyBarrierForTesting = newValue } }
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        try codingLock.withLock { try encoder.encode(value) }
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try codingLock.withLock { try decoder.decode(type, from: data) }
    }

    /// Installs a complete credential pair as one in-memory generation. AppState
    /// persists the atomic envelope before calling this method.
    @discardableResult
    func installSession(
        identity: String,
        accessToken: String,
        refreshToken: String,
        persistTokenRotation: Bool = false
    ) -> SessionSnapshot {
        let result = stateLock.withLock { () -> (SessionSnapshot, Task<Void, Error>?) in
            let refresh = invalidateCredentialGenerationLocked()
            cachedCacheIdentity = identity
            cachedAccessToken = accessToken
            cachedRefreshToken = refreshToken
            requiresPersistedTokenRotation = persistTokenRotation
            let snapshot = SessionSnapshot(
                identity: identity,
                generation: credentialGeneration,
                accessToken: accessToken,
                refreshToken: refreshToken
            )
            return (snapshot, refresh)
        }
        result.1?.cancel()
        cancelInflightRequests()
        return result.0
    }

    /// Atomically invalidates the local credential generation and cancels work
    /// that was created under it. This prevents an old refresh task from blocking
    /// or overwriting the next account's credentials.
    func clearSession() {
        let refresh = stateLock.withLock { () -> Task<Void, Error>? in
            let task = invalidateCredentialGenerationLocked()
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedCacheIdentity = nil
            requiresPersistedTokenRotation = false
            return task
        }
        refresh?.cancel()
        cancelInflightRequests()
    }

    /// Updates only the cached profile payload while holding the same lock used
    /// by token rotation. Whichever operation wins the lock reads the other one's
    /// authoritative values first, so a stale profile snapshot can never roll
    /// refreshed credentials back in Keychain.
    func updateStoredProfile(identity: String, userJSON: String) throws {
        try stateLock.withLock {
            guard let current = currentSessionSnapshotLocked(),
                  current.identity == identity,
                  let envelope = try loadSessionEnvelope(),
                  envelope.identity == current.identity,
                  envelope.accessToken == current.accessToken,
                  envelope.refreshToken == current.refreshToken else {
                throw KeychainError.invalidSessionEnvelope
            }
            let updated = StoredSessionEnvelope(
                identity: current.identity,
                accessToken: current.accessToken,
                refreshToken: current.refreshToken,
                userJSON: userJSON
            )
            try saveSessionEnvelope(updated)
            guard let verified = try loadSessionEnvelope(), verified == updated else {
                throw KeychainError.invalidSessionEnvelope
            }
        }
    }

    func flushOfflineMutations() async {
        let lease = inflightLock.withLock { () -> (id: UUID, task: Task<Void, Never>) in
            if let task = offlineMutationFlushTask,
               let id = offlineMutationFlushID {
                return (id, task)
            }

            let id = UUID()
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.performOfflineMutationFlush()
            }
            offlineMutationFlushTask = task
            offlineMutationFlushID = id
            return (id, task)
        }

        await lease.task.value
        inflightLock.withLock {
            guard offlineMutationFlushID == lease.id else { return }
            offlineMutationFlushTask = nil
            offlineMutationFlushID = nil
        }
    }

    private func performOfflineMutationFlush() async {
        guard let initialSession = currentSessionSnapshot() else { return }
        let identity = initialSession.identity
        while isCurrentSession(initialSession), !Task.isCancelled {
            let mutation: QueuedHTTPMutation
            do {
                guard let claimed = try await offlineMutationStore.claimNext(
                    identity: identity
                ) else { return }
                mutation = claimed
            } catch {
                Self.logger.error("Could not read the offline HTTP queue: \(error.localizedDescription)")
                return
            }

            guard isCurrentSession(initialSession) else {
                await releaseOfflineClaim(
                    id: mutation.id,
                    identity: identity,
                    disposition: .cancelled,
                    context: "session replacement before replay"
                )
                return
            }
            do {
                try await executeQueuedMutation(mutation, expectedSession: initialSession)
            } catch {
                if Self.isCancellation(error) || !isCurrentSession(initialSession) {
                    await releaseOfflineClaim(
                        id: mutation.id,
                        identity: identity,
                        disposition: .cancelled,
                        context: "cancelled replay"
                    )
                    return
                }
                if (error as? APIError)?.isAuthError == true {
                    await releaseOfflineClaim(
                        id: mutation.id,
                        identity: identity,
                        disposition: .authentication,
                        context: "authentication failure"
                    )
                    return
                }
                if isPermanentOfflineMutationFailure(error) {
                    do {
                        try await offlineMutationStore.markPermanent(
                            id: mutation.id,
                            identity: identity,
                            error: error.localizedDescription,
                            statusCode: Self.statusCode(for: error)
                        )
                    } catch {
                        Self.logger.error(
                            "Could not persist an offline HTTP dead letter: \(error.localizedDescription)"
                        )
                        return
                    }
                    continue
                }
                do {
                    try await offlineMutationStore.markRetryable(
                        id: mutation.id,
                        identity: identity,
                        error: error.localizedDescription,
                        statusCode: Self.statusCode(for: error)
                    )
                } catch {
                    Self.logger.error(
                        "Could not persist offline HTTP retry state: \(error.localizedDescription)"
                    )
                }
                // A transient transport/server failure is likely shared by later
                // items. Respect backoff rather than hammering every queue entry.
                return
            }

            // Transport succeeded. A local acknowledgement failure is not a
            // server rejection: retain the stable operation ID and release the
            // claim for idempotent replay instead of dead-lettering an action
            // the server may already have applied.
            do {
                try await offlineMutationStore.complete(
                    id: mutation.id,
                    identity: identity
                )
            } catch {
                Self.logger.error(
                    "Could not persist an offline HTTP acknowledgement: \(error.localizedDescription)"
                )
                await releaseOfflineClaim(
                    id: mutation.id,
                    identity: identity,
                    disposition: .cancelled,
                    context: "acknowledgement persistence failure"
                )
                return
            }
        }
    }

    private enum OfflineClaimDisposition {
        case cancelled
        case authentication
    }

    /// A failed release save remains visible and recoverable. Both store release
    /// methods clear their process-local claim before writing; claimNext() in a
    /// later flush resets any persisted in-flight row that has no runtime claim.
    private func releaseOfflineClaim(
        id: String,
        identity: String,
        disposition: OfflineClaimDisposition,
        context: String
    ) async {
        do {
            switch disposition {
            case .cancelled:
                try await offlineMutationStore.releaseAfterCancellation(
                    id: id,
                    identity: identity
                )
            case .authentication:
                try await offlineMutationStore.releaseForAuthentication(
                    id: id,
                    identity: identity
                )
            }
        } catch {
            Self.logger.error(
                "Offline queue claim release failed after \(context, privacy: .public): \(error.localizedDescription, privacy: .public). Reconciliation: the next flush reclaims persisted in-flight rows without a runtime claim."
            )
        }
    }

    func pendingOfflineMutationCount() async -> Int {
        guard let identity = cacheIdentity else { return 0 }
        do {
            return try await offlineMutationStore.count(identity: identity)
        } catch {
            // This is display-only diagnostics; never mutate or discard queue
            // state because inspection failed. The next screen refresh retries.
            Self.logger.error(
                "Offline queue count inspection failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next settings refresh retries queue inspection."
            )
            return 0
        }
    }

    func inspectOfflineMutations() async -> [OfflineHTTPMutationSummary] {
        guard let identity = cacheIdentity else { return [] }
        do {
            return try await offlineMutationStore.summaries(identity: identity)
        } catch {
            // Summaries are display-only diagnostics. Preserve the durable
            // queue unchanged and retry through the next explicit inspection.
            Self.logger.error(
                "Offline queue summary inspection failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next explicit inspection retries the durable read."
            )
            return []
        }
    }

    func purgeOfflineMutations(identity: String) async throws {
        try await offlineMutationStore.purge(identity: identity)
    }

    private func executeQueuedMutation(
        _ mutation: QueuedHTTPMutation,
        expectedSession: SessionSnapshot
    ) async throws {
        guard isCurrentSession(expectedSession) else { throw APIError.unauthorized }
        var request = try buildRequest(path: mutation.path, method: mutation.method)
        request.httpBody = mutation.body
        if let contentType = mutation.contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        } else if mutation.body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(mutation.id, forHTTPHeaderField: Self.operationIDHeader)
        if let bodyFile = try await offlineMutationStore.bodyFileURL(for: mutation) {
            try await executeUploadNoResponseOnline(
                request,
                bodyFile: bodyFile,
                path: mutation.path,
                isRetry: false
            )
        } else {
            try await executeNoResponseOnline(request, path: mutation.path, isRetry: false)
        }
        guard isCurrentSession(expectedSession) else { throw APIError.unauthorized }
    }

    private func cancelInflightRequests() {
        let inflight = inflightLock.withLock { () -> (
            [Task<Data, Error>],
            [Task<DataTransportResponse, Error>],
            [Task<DataTransportResponse, Error>],
            [Task<DownloadTransportResponse, Error>],
            Task<Void, Never>?
        ) in
            let requests = inflightRequests.values.map(\.task)
            let dataTransfers = Array(inflightDataTransfers.values)
            let uploads = Array(inflightUploads.values)
            let downloads = Array(inflightDownloads.values)
            let mutationFlush = offlineMutationFlushTask
            inflightRequests.removeAll()
            inflightDataTransfers.removeAll()
            inflightUploads.removeAll()
            inflightDownloads.removeAll()
            offlineMutationFlushTask = nil
            offlineMutationFlushID = nil
            return (requests, dataTransfers, uploads, downloads, mutationFlush)
        }
        for request in inflight.0 { request.cancel() }
        for dataTransfer in inflight.1 { dataTransfer.cancel() }
        for upload in inflight.2 { upload.cancel() }
        for download in inflight.3 { download.cancel() }
        inflight.4?.cancel()
    }

    // MARK: - Public Methods

    private static func validatedRequestPath(_ path: APIRequestPath) throws -> String {
        do {
            return try path.validatedValue()
        } catch {
            throw APIError.invalidURL
        }
    }

    /// Compatibility entry point. `bypassCache` means network-first while still
    /// retaining the established offline fallback contract.
    func get<T: Decodable>(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil,
        bypassCache: Bool = false
    ) async throws -> T {
        try await get(
            path,
            queryItems: queryItems,
            cachePolicy: bypassCache ? .networkThenStale : .cacheFirst
        )
    }

    /// Performs a GET under an explicit cache contract. Safety and live-state
    /// endpoints should use `.networkOnly` so an offline response cannot be
    /// mistaken for current server state.
    func get<T: Decodable>(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil,
        cachePolicy: GetCachePolicy
    ) async throws -> T {
        let response: ProvenancedGet<T> = try await getWithProvenance(
            path,
            queryItems: queryItems,
            cachePolicy: cachePolicy
        )
        return response.value
    }

    /// Performs the same GET as `get`, while exposing whether the decoded value
    /// came from the network, a normal fresh cache hit, or an offline fallback.
    /// The default GET path delegates here so provenance cannot drift from its
    /// existing cache and authentication behavior.
    func getWithProvenance<T: Decodable>(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil,
        bypassCache: Bool = false
    ) async throws -> ProvenancedGet<T> {
        try await getWithProvenance(
            path,
            queryItems: queryItems,
            cachePolicy: bypassCache ? .networkThenStale : .cacheFirst
        )
    }

    func getWithProvenance<T: Decodable>(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil,
        cachePolicy: GetCachePolicy
    ) async throws -> ProvenancedGet<T> {
        let path = try Self.validatedRequestPath(path)
        let request = try buildRequest(path: path, method: "GET", queryItems: queryItems)
        let requestLease = try captureSessionLease(for: request)
        let cacheKey = try responseCacheKey(for: request, lease: requestLease)
        let cacheable = cachePolicy != .networkOnly && isCacheableGetPath(path)

        // Check the memory-backed file cache for fresh data.
        if cacheable,
           cachePolicy == .cacheFirst,
           let cached = await FileCache.shared.get(
               cacheKey,
               maximumBytes: Self.maximumJSONResponseBytes
           ),
           !cached.isStale {
            await cacheReadBarrierForTesting?()
            try ensureCurrent(requestLease)
            do {
                let decoded = try decodeJSON(T.self, from: cached.data)
                try ensureCurrent(requestLease)
                return ProvenancedGet(value: decoded, provenance: .freshCache)
            } catch {
                if !isCurrent(requestLease) {
                    throw APIError.unauthorized
                }
                Self.logger.debug("Cache decode failed for \(path), fetching from network")
            }
        }

        do {
            // Deduplicate in-flight GET requests
            let lease = inflightTask(for: cacheKey) {
                let (responseData, response) = try await self.transportResponse(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIError.networkError(URLError(.badServerResponse))
                }

                // Handle 401 — attempt token refresh and retry
                if httpResponse.statusCode == 401 && self.shouldAttemptTokenRefresh(for: request) {
                    guard let expectedSession = requestLease.session,
                          self.isCurrentSession(expectedSession) else {
                        throw APIError.unauthorized
                    }
                    do {
                        try await self.refreshAccessToken(expectedSession: expectedSession)
                    } catch {
                        if self.shouldDeliverAuthFailure(for: error) {
                            await self.deliverAuthFailureIfCurrent(expectedSession)
                        }
                        throw error
                    }
                    guard let token = self.accessToken(ifCurrent: expectedSession) else {
                        throw APIError.unauthorized
                    }
                    var retryRequest = request
                    retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    guard self.isCurrentSession(expectedSession) else {
                        throw APIError.unauthorized
                    }
                    let (retryData, retryResponse) = try await self.transportResponse(
                        for: retryRequest
                    )
                    guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                        throw APIError.networkError(URLError(.badServerResponse))
                    }
                    try self.validateStatusCode(retryHTTP.statusCode, data: retryData)
                    try self.ensureCurrent(requestLease)
                    return retryData
                }

                try self.validateStatusCode(httpResponse.statusCode, data: responseData)
                try self.ensureCurrent(requestLease)
                return responseData
            }
            defer {
                releaseInflightTask(
                    for: cacheKey, waiterID: lease.waiterID, cancelIfLast: false
                )
            }

            if !lease.isFirstWaiter {
                Self.logger.debug("Deduplicating GET request for \(path)")
            }
            let data = try await withTaskCancellationHandler {
                try await lease.task.value
            } onCancel: {
                self.releaseInflightTask(
                    for: cacheKey, waiterID: lease.waiterID, cancelIfLast: true
                )
            }
            try Task.checkCancellation()
            try ensureCurrent(requestLease)

            do {
                let decoded = try decodeJSON(T.self, from: data)
                try ensureCurrent(requestLease)
                if cacheable && claimInflightCacheWrite(
                    for: cacheKey, waiterID: lease.waiterID
                ) {
                    // Publish the in-memory copy before returning, then make it
                    // durable without delaying the first network-backed paint.
                    try await rememberSuccessfulGetResponse(
                        data, cacheKey: cacheKey, lease: requestLease
                    )
                    scheduleSuccessfulGetCache(
                        data, cacheKey: cacheKey, lease: requestLease
                    )
                }
                return ProvenancedGet(value: decoded, provenance: .network)
            } catch {
                if !isCurrent(requestLease) {
                    throw APIError.unauthorized
                }
                throw APIError.decodingError(error)
            }
        } catch {
            // An earlier account's failure must not fall back to that account's
            // cache after a replacement login has become authoritative.
            guard isCurrent(requestLease) else {
                throw APIError.unauthorized
            }
            // Only an actual transport failure may use stale data. Authentication,
            // permission, status, cancellation, and decoding failures must remain
            // visible to the caller instead of being masked by an old response.
            if isOfflineTransportError(error),
               cacheable,
               let cached = await FileCache.shared.get(
                   cacheKey,
                   maximumBytes: Self.maximumJSONResponseBytes
               ),
               cachePolicy == .networkThenStale || cached.isStale {
                try ensureCurrent(requestLease)
                Self.logger.info("Using stale cache for \(path) after network error")
                do {
                    let decoded = try decodeJSON(T.self, from: cached.data)
                    try ensureCurrent(requestLease)
                    return ProvenancedGet(value: decoded, provenance: .staleFallback)
                } catch {
                    if !isCurrent(requestLease) {
                        throw APIError.unauthorized
                    }
                    // If stale cache is unusable, bubble original error
                }
            }
            throw error
        }
    }

    /// Normalizes transport failures consistently for every HTTP method.
    /// Cancellation remains cancellation: callers must never interpret a stopped
    /// request as an offline write that should be queued for later execution.
    private func transportResponse(for request: URLRequest) async throws -> (Data, URLResponse) {
        let transport = try await transportDataResponse(
            for: request,
            successMaximumBytes: Self.maximumJSONResponseBytes
        )
        do {
            let data = transport.data
            if (200...299).contains(transport.response.statusCode), !data.isEmpty {
                let mediaType = BoundedHTTPPayload.normalizedMediaType(
                    transport.response.value(forHTTPHeaderField: "Content-Type")
                )
                guard Self.isJSONMediaType(mediaType) else {
                    throw BoundedHTTPPayload.ValidationError.unexpectedMediaType(mediaType)
                }
            }
            return (data, transport.response)
        } catch {
            if Self.isCancellation(error) {
                throw error
            }
            if error is BoundedHTTPPayload.ValidationError {
                throw APIError.decodingError(error)
            }
            throw APIError.decodingError(error)
        }
    }

    private func transportDataResponse(
        for request: URLRequest,
        successMaximumBytes: Int
    ) async throws -> DataTransportResponse {
        let taskID = UUID()
        let task = Task { [session, transportDelegate] () throws -> DataTransportResponse in
            do {
                let response = try await transportDelegate.response(
                    for: request,
                    in: session,
                    successMaximumBytes: successMaximumBytes,
                    errorMaximumBytes: Self.maximumErrorResponseBytes
                )
                guard let data = response.data else {
                    throw BoundedHTTPPayload.ValidationError.invalidResponse
                }
                return DataTransportResponse(data: data, response: response.response)
            } catch {
                if Self.isCancellation(error) { throw error }
                if error is APIError { throw error }
                if error is BoundedHTTPPayload.ValidationError {
                    throw APIError.decodingError(error)
                }
                throw APIError.networkError(error)
            }
        }
        inflightLock.withLock { inflightDataTransfers[taskID] = task }
        defer {
            _ = inflightLock.withLock { inflightDataTransfers.removeValue(forKey: taskID) }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func isJSONMediaType(_ mediaType: String?) -> Bool {
        guard let mediaType else { return false }
        return mediaType == "application/json"
            || (mediaType.hasPrefix("application/") && mediaType.hasSuffix("+json"))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    private func isOfflineTransportError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        if case .networkError = apiError {
            return true
        }
        return false
    }

    private func isPermanentOfflineMutationFailure(_ error: Error) -> Bool {
        if error is OfflineHTTPMutationStoreError { return true }
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .invalidURL, .forbidden, .notFound, .conflict, .decodingError:
            return true
        case .serverError(let statusCode, _):
            return (400...499).contains(statusCode)
                && ![408, 425, 429].contains(statusCode)
        case .unauthorized, .networkError, .offlineQueued, .offlineQueueFull,
             .tokenRefreshFailed:
            return false
        }
    }

    private static func statusCode(for error: Error) -> Int? {
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

    private func isOfflineQueueable(
        path: String,
        method: String,
        request: URLRequest,
        hasBodyFile: Bool = false
    ) -> Bool {
        OfflineHTTPMutationStore.allows(
            path: path,
            method: method,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            hasInlineBody: request.httpBody != nil,
            hasBodyFile: hasBodyFile
        )
    }

    private func enqueueOfflineMutation<T: Decodable>(
        request: URLRequest,
        path: String,
        transportError: Error
    ) async throws -> T {
        guard isOfflineTransportError(transportError),
              let method = request.httpMethod,
              isOfflineQueueable(path: path, method: method, request: request),
              let session = sessionSnapshot(for: request),
              let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) else {
            throw transportError
        }
        let mutation = QueuedHTTPMutation(
            id: operationID,
            identity: session.identity,
            method: method,
            path: path,
            body: request.httpBody,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            createdAt: Date(),
            retryCount: 0,
            lastError: nil
        )
        do {
            try await offlineMutationStore.enqueue(mutation)
        } catch OfflineHTTPMutationStoreError.capacityExceeded {
            throw APIError.offlineQueueFull
        } catch {
            throw transportError
        }
        let optimistic = await optimisticMutationResponse(request: request, path: path)
        await applyOfflineMutationToCache(request: request, path: path, optimistic: optimistic)
        // This synthetic response is optional UX after a durable enqueue. A
        // model mismatch surfaces the canonical queued-state outcome.
        guard let optimistic,
              let decoded = try? decodeJSON(T.self, from: optimistic) else {
            throw APIError.offlineQueued
        }
        return decoded
    }

    private func enqueueOfflineNoResponse(
        request: URLRequest,
        path: String,
        transportError: Error
    ) async throws -> Bool {
        guard isOfflineTransportError(transportError),
              let method = request.httpMethod,
              isOfflineQueueable(path: path, method: method, request: request),
              let session = sessionSnapshot(for: request),
              let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) else {
            return false
        }
        do {
            try await offlineMutationStore.enqueue(
                QueuedHTTPMutation(
                    id: operationID,
                    identity: session.identity,
                    method: method,
                    path: path,
                    body: request.httpBody,
                    contentType: request.value(forHTTPHeaderField: "Content-Type"),
                    createdAt: Date(),
                    retryCount: 0,
                    lastError: nil
                )
            )
            let optimistic = method == "DELETE"
                ? nil
                : await optimisticMutationResponse(request: request, path: path)
            await applyOfflineMutationToCache(request: request, path: path, optimistic: optimistic)
            return true
        } catch OfflineHTTPMutationStoreError.capacityExceeded {
            throw APIError.offlineQueueFull
        } catch {
            return false
        }
    }

    private func optimisticMutationResponse(request: URLRequest, path: String) async -> Data? {
        var requestValues: [String: Any] = [:]
        // Optimistic cache projection accepts JSON objects only. Unsupported
        // bodies skip the projection; replay durability is independent of it.
        if let body = request.httpBody,
           let decoded = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            requestValues = decoded
        }
        let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) ?? UUID().uuidString
        let cleanPath = path.components(separatedBy: "?").first ?? path
        let segments = cleanPath.split(separator: "/").map(String.init)
        let actions = Set(["complete", "reopen", "check", "end", "renewed", "dismiss", "activate", "adjust"])
        let last = segments.last
        let pathID: String? = {
            guard let last else { return nil }
            if actions.contains(last), segments.count > 1 { return segments[segments.count - 2] }
            if !actions.contains(last), segments.count > 1,
               !["activities", "vaccinations", "reading", "spellings", "ideas", "items", "terms", "stars"].contains(last) {
                return last
            }
            return nil
        }()
        let recordID = requestValues["id"] as? String ?? pathID ?? operationID
        let cachedRecordData = await FileCache.shared.jsonRecordData(id: recordID)
        var object = cachedRecordData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        object.merge(requestValues) { _, new in new }
        let now = ISO8601DateFormatter().string(from: Date())
        object["id"] = recordID
        object["created_at"] = object["created_at"] ?? now
        object["updated_at"] = now
        object["queued_offline"] = true
        if cleanPath.hasSuffix("/complete") { object["completed_at"] = now }
        if cleanPath.hasSuffix("/reopen") { object["completed_at"] = NSNull() }
        if cleanPath.hasSuffix("/check") { object["checked"] = !((object["checked"] as? Bool) ?? false) }
        if cleanPath == "/meals/shopping" { object["checked"] = object["checked"] ?? false }
        if cleanPath.hasPrefix("/renewals") {
            if cleanPath.hasSuffix("/renewed"),
               let months = object["recurrence_months"] as? Int,
               let dueDate = object["due_date"] as? String,
               let due = ISODateParser.parseDateOnly(dueDate),
               let advanced = Calendar.current.date(byAdding: .month, value: months, to: due) {
                object["due_date"] = ISODateParser.stringDateOnly(from: advanced)
            }
            if let dueDate = object["due_date"] as? String,
               let due = ISODateParser.parseDateOnly(dueDate) {
                let calendar = Calendar.current
                let days = calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: Date()),
                    to: calendar.startOfDay(for: due)
                ).day ?? 0
                let reminderDays = object["reminder_days_before"] as? Int ?? 30
                object["days_until"] = days
                object["status"] = days < 0 ? "overdue" : days <= reminderDays ? "due_soon" : "upcoming"
                object["reminder_days_before"] = reminderDays
            }
        }
        // Non-JSON-compatible values simply make the optional projection
        // unavailable and fall back to the durable queued-state result.
        return try? JSONSerialization.data(withJSONObject: object)
    }

    private func applyOfflineMutationToCache(
        request: URLRequest,
        path: String,
        optimistic: Data?
    ) async {
        guard let method = request.httpMethod else { return }
        let cleanPath = path.components(separatedBy: "?").first ?? path
        let segments = cleanPath.split(separator: "/").map(String.init)
        let actionNames = Set(["complete", "reopen", "check", "end", "renewed", "dismiss", "activate", "adjust"])
        let action = segments.last.flatMap { actionNames.contains($0) ? $0 : nil }
        // This is presentation-only cache projection, not the replay source of
        // truth. Non-object JSON intentionally maps to an empty patch.
        var body = (request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }) ?? [:]
        let pathID: String? = {
            if action != nil, segments.count > 1 { return segments[segments.count - 2] }
            if method != "POST", let last = segments.last { return last }
            return nil
        }()
        if let optimistic,
           let object = try? JSONSerialization.jsonObject(with: optimistic) as? [String: Any] {
            body.merge(object) { _, new in new }
        }
        let recordID = body["id"] as? String
            ?? pathID
            ?? request.value(forHTTPHeaderField: Self.operationIDHeader)
        guard let recordID else { return }
        body["id"] = recordID

        let collectionPath: String = {
            if cleanPath.hasPrefix("/meals/shopping") { return "/meals/shopping" }
            if action != nil, segments.count > 2 {
                return "/" + segments.dropLast(2).joined(separator: "/")
            }
            if method != "POST", segments.count > 1 {
                return "/" + segments.dropLast().joined(separator: "/")
            }
            return cleanPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
                ? "/"
                : "/" + segments.joined(separator: "/")
        }()
        let prefix = baseURL + collectionPath
        await FileCache.shared.updateJSON(where: { key in
            guard key.hasPrefix(prefix) else { return false }
            let boundary = key.dropFirst(prefix.count).first
            return boundary == nil || boundary == "/" || boundary == "?" || boundary == "#"
        }) { value in
            guard var items = value as? [[String: Any]] else { return value }
            guard let index = items.firstIndex(where: { $0["id"] as? String == recordID }) else {
                if method == "POST" { items.insert(body, at: 0) }
                return items
            }
            if method == "DELETE" {
                items.remove(at: index)
            } else if action == "check" {
                var item = items[index]
                item["checked"] = !((item["checked"] as? Bool) ?? false)
                items[index] = item
            } else {
                items[index].merge(body) { _, new in new }
            }
            return items
        }
    }

    /// Performs a POST request with an encodable body and decodes the response.
    func post<T: Decodable, B: Encodable>(
        _ path: APIRequestPath,
        body: B,
        queryItems: [URLQueryItem]? = nil,
        operationID: String? = nil
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(
            path: path,
            method: "POST",
            queryItems: queryItems,
            operationID: operationID
        )
        request.httpBody = try encodeJSON(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request, path: path)
    }

    /// Performs a POST endpoint whose contract has no request body.
    func post<T: Decodable>(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        let request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        return try await execute(request,path: path)
    }

    /// Performs a POST whose server-side work is expected to outlive the normal
    /// interactive request timeout. The caller still owns task cancellation.
    func post<T: Decodable, B: Encodable>(
        _ path: APIRequestPath,
        body: B,
        timeoutInterval: TimeInterval,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        request.timeoutInterval = timeoutInterval
        request.httpBody = try encodeJSON(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request, path: path)
    }

    private typealias MultipartField = MultipartRequestBodyBuilder.Field
    private typealias MultipartFilePart = MultipartRequestBodyBuilder.FilePart

    private static func removeTemporaryTransferBestEffort(
        _ directory: URL,
        fileManager: FileManager,
        context: String
    ) {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "\(context, privacy: .public) cleanup failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next API client initialization retries aged HausKlar transfer cleanup."
            )
        }
    }

    /// Uploads one file and text fields as multipart/form-data.
    func uploadMultipart<T: Decodable>(
        _ path: APIRequestPath,
        fileURL: URL,
        filename: String,
        mediaType: String,
        fields: [String: String],
        queryItems: [URLQueryItem]? = nil,
        offlineReplayPolicy: MultipartOfflineReplayPolicy = .genericQueue
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        var uploadFields = fields
        if path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "artworks",
           uploadFields["client_id"] == nil,
           let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) {
            uploadFields["client_id"] = operationID
        }
        if path.components(separatedBy: "?").first == "/finance/purchases/evidence/upload",
           uploadFields["source_id"] == nil,
           let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) {
            uploadFields["source_id"] = operationID
        }
        let boundary = "HausKlar-\(UUID().uuidString)"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let requestLease = try captureSessionLease(for: request)
        let root = transferTemporaryRoot
        let fields = uploadFields.keys.sorted().compactMap { key in
            uploadFields[key].map { MultipartField(name: key, value: $0) }
        }
        let file = MultipartFilePart(
            fieldName: "file",
            filename: filename,
            mediaType: mediaType,
            source: .file(fileURL)
        )
        let body = try await Task.detached(priority: .utility) {
            try MultipartRequestBodyBuilder.create(
                boundary: boundary,
                fields: fields,
                files: [file],
                root: root
            )
        }.value
        defer {
            Self.removeTemporaryTransferBestEffort(
                body.directory,
                fileManager: .default,
                context: "multipart upload"
            )
        }
        await transferReadyBarrierForTesting?()
        try Task.checkCancellation()
        try ensureCurrent(requestLease)
        do {
            return try await executeMultipart(
                request,
                bodyFile: body.file,
                path: path,
                lease: requestLease
            )
        } catch {
            guard offlineReplayPolicy == .genericQueue else { throw error }
            return try await enqueueOfflineMultipartMutation(
                request: request,
                path: path,
                bodyFile: body.file,
                transportError: error,
                lease: requestLease
            )
        }
    }

    /// Compatibility overload for callers that already hold small files in memory.
    func uploadMultipartFiles<T: Decodable>(
        _ path: APIRequestPath,
        fileFieldName: String,
        files: [(filename: String, mediaType: String, data: Data)],
        orderedFields: [(name: String, value: String)],
        method: String = "POST"
    ) async throws -> T {
        try await uploadMultipartFileParts(
            path,
            files: files.map {
                MultipartFilePart(
                    fieldName: fileFieldName,
                    filename: $0.filename,
                    mediaType: $0.mediaType,
                    source: .data($0.data)
                )
            },
            orderedFields: orderedFields,
            method: method,
            maximumSourceBytes: nil
        )
    }

    /// Streams several regular local files under one repeated field name, plus
    /// ordered text fields (which may repeat), into a protected multipart body.
    /// Part order is preserved so the server can zip repeated fields (for example
    /// `taken_on`) to `files` by index. Sources are rejected before staging if
    /// they are symlinks, non-regular files, or exceed the bounded request total.
    func uploadMultipartFiles<T: Decodable>(
        _ path: APIRequestPath,
        fileFieldName: String,
        files: [(filename: String, mediaType: String, fileURL: URL)],
        orderedFields: [(name: String, value: String)],
        method: String = "POST"
    ) async throws -> T {
        try await uploadMultipartFileParts(
            path,
            files: files.map {
                MultipartFilePart(
                    fieldName: fileFieldName,
                    filename: $0.filename,
                    mediaType: $0.mediaType,
                    source: .file($0.fileURL)
                )
            },
            orderedFields: orderedFields,
            method: method,
            maximumSourceBytes: Self.maximumFileBackedMultipartSourceBytes
        )
    }

    private func uploadMultipartFileParts<T: Decodable>(
        _ path: APIRequestPath,
        files: [MultipartFilePart],
        orderedFields: [(name: String, value: String)],
        method: String,
        maximumSourceBytes: Int?
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(path: path, method: method)
        var replayFields = orderedFields
        if path.components(separatedBy: "?").first == "/child-photos/",
           let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) {
            let currentIDs = replayFields.filter { $0.name == "client_id" }.count
            for index in currentIDs..<files.count {
                replayFields.append(("client_id", "\(operationID)-\(index + 1)"))
            }
        }
        if path.range(of: #"^/family/members/[^/]+/avatar$"#, options: .regularExpression) != nil,
           !replayFields.contains(where: { $0.name == "operation_id" }),
           let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) {
            replayFields.append(("operation_id", operationID))
        }
        let boundary = "HausKlar-\(UUID().uuidString)"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let requestLease = try captureSessionLease(for: request)
        let root = transferTemporaryRoot
        let bodyFields = replayFields.map { MultipartField(name: $0.name, value: $0.value) }
        let body = try await Task.detached(priority: .utility) {
            try MultipartRequestBodyBuilder.create(
                boundary: boundary,
                fields: bodyFields,
                files: files,
                root: root,
                maximumSourceBytes: maximumSourceBytes
            )
        }.value
        defer {
            Self.removeTemporaryTransferBestEffort(
                body.directory,
                fileManager: .default,
                context: "multipart upload"
            )
        }
        await transferReadyBarrierForTesting?()
        try Task.checkCancellation()
        try ensureCurrent(requestLease)
        do {
            return try await executeMultipart(
                request,
                bodyFile: body.file,
                path: path,
                lease: requestLease
            )
        } catch {
            return try await enqueueOfflineMultipartMutation(
                request: request,
                path: path,
                bodyFile: body.file,
                transportError: error,
                lease: requestLease
            )
        }
    }

    private func executeMultipart<T: Decodable>(
        _ request: URLRequest,
        bodyFile: URL,
        path: String,
        lease: RequestSessionLease
    ) async throws -> T {
        let data = try await executeUploadDataOnline(
            request,
            bodyFile: bodyFile,
            path: path,
            isRetry: false
        )
        try ensureCurrent(lease)
        do {
            let decoded = try decodeJSON(T.self, from: data)
            try ensureCurrent(lease)
            return decoded
        } catch {
            guard isCurrent(lease) else { throw APIError.unauthorized }
            throw APIError.decodingError(error)
        }
    }

    private func executeUploadNoResponseOnline(
        _ request: URLRequest,
        bodyFile: URL,
        path: String,
        isRetry: Bool
    ) async throws {
        _ = try await executeUploadDataOnline(
            request,
            bodyFile: bodyFile,
            path: path,
            isRetry: isRetry
        )
    }

    private func executeUploadDataOnline(
        _ request: URLRequest,
        bodyFile: URL,
        path: String,
        isRetry: Bool
    ) async throws -> Data {
        let transport = try await transportUploadResponse(for: request, fromFile: bodyFile)
        if transport.response.statusCode == 401 && !isRetry && shouldAttemptTokenRefresh(for: request) {
            guard let expectedSession = sessionSnapshot(for: request) else {
                throw APIError.unauthorized
            }
            do {
                try await refreshAccessToken(expectedSession: expectedSession)
            } catch {
                if shouldDeliverAuthFailure(for: error) {
                    await deliverAuthFailureIfCurrent(expectedSession)
                }
                throw error
            }
            guard let token = accessToken(ifCurrent: expectedSession) else {
                throw APIError.unauthorized
            }
            var retry = request
            retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard sessionSnapshot(for: retry)?.key == expectedSession.key else {
                throw APIError.unauthorized
            }
            return try await executeUploadDataOnline(
                retry,
                bodyFile: bodyFile,
                path: path,
                isRetry: true
            )
        }
        try validateStatusCode(transport.response.statusCode, data: transport.data)
        try ensureCurrentSessionGeneration(for: request)
        await invalidateGetCache(for: path)
        try ensureCurrentSessionGeneration(for: request)
        return transport.data
    }

    private func transportUploadResponse(
        for request: URLRequest,
        fromFile bodyFile: URL
    ) async throws -> DataTransportResponse {
        let taskID = UUID()
        let task = Task { [session, transportDelegate] () throws -> DataTransportResponse in
            do {
                let response = try await transportDelegate.uploadResponse(
                    for: request,
                    fromFile: bodyFile,
                    in: session,
                    successMaximumBytes: Self.maximumJSONResponseBytes,
                    errorMaximumBytes: Self.maximumErrorResponseBytes
                )
                guard let data = response.data else {
                    throw BoundedHTTPPayload.ValidationError.invalidResponse
                }
                if (200...299).contains(response.response.statusCode), !data.isEmpty {
                    let mediaType = BoundedHTTPPayload.normalizedMediaType(
                        response.response.value(forHTTPHeaderField: "Content-Type")
                    )
                    guard Self.isJSONMediaType(mediaType) else {
                        throw BoundedHTTPPayload.ValidationError.unexpectedMediaType(mediaType)
                    }
                }
                return DataTransportResponse(data: data, response: response.response)
            } catch {
                if Self.isCancellation(error) { throw error }
                if error is APIError { throw error }
                if error is BoundedHTTPPayload.ValidationError {
                    throw APIError.decodingError(error)
                }
                throw APIError.networkError(error)
            }
        }
        inflightLock.withLock { inflightUploads[taskID] = task }
        defer { _ = inflightLock.withLock { inflightUploads.removeValue(forKey: taskID) } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func enqueueOfflineMultipartMutation<T: Decodable>(
        request: URLRequest,
        path: String,
        bodyFile: URL,
        transportError: Error,
        lease: RequestSessionLease
    ) async throws -> T {
        guard isOfflineTransportError(transportError),
              let method = request.httpMethod,
              isOfflineQueueable(
                path: path,
                method: method,
                request: request,
                hasBodyFile: true
              ),
              let session = lease.session,
              isCurrent(lease),
              let operationID = request.value(forHTTPHeaderField: Self.operationIDHeader) else {
            throw transportError
        }
        let mutation = QueuedHTTPMutation(
            id: operationID,
            identity: session.identity,
            method: method,
            path: path,
            body: nil,
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            createdAt: Date()
        )
        do {
            try await offlineMutationStore.enqueue(mutation, bodyFile: bodyFile)
        } catch OfflineHTTPMutationStoreError.capacityExceeded {
            throw APIError.offlineQueueFull
        } catch {
            throw transportError
        }
        try ensureCurrent(lease)
        let optimistic = await optimisticMutationResponse(request: request, path: path)
        await applyOfflineMutationToCache(request: request, path: path, optimistic: optimistic)
        // The multipart body is already durable. A synthetic response that does
        // not decode as T uses the explicit queued-state outcome instead.
        guard let optimistic,
              let decoded = try? decodeJSON(T.self, from: optimistic) else {
            throw APIError.offlineQueued
        }
        return decoded
    }

    /// Downloads authenticated response data without JSON decoding.
    func downloadData(
        _ path: APIRequestPath,
        policy: DownloadDataPolicy,
        cachePolicy: GetCachePolicy = .cacheFirst,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        let path = try Self.validatedRequestPath(path)
        guard policy.maximumBytes > 0, !policy.allowedMediaTypes.isEmpty else {
            throw APIError.decodingError(BoundedHTTPPayload.ValidationError.invalidResponse)
        }
        let request = try buildRequest(
            path: path,
            method: "GET",
            queryItems: queryItems
        )
        let requestLease = try captureSessionLease(for: request)
        let cacheKey = try responseCacheKey(for: request, lease: requestLease)
        let inflightKey = cacheKey + policy.inflightSuffix
        let cacheable = cachePolicy != .networkOnly && isCacheableGetPath(path)
        if cacheable,
           cachePolicy == .cacheFirst,
           let cached = await FileCache.shared.get(
               cacheKey,
               maximumBytes: policy.maximumBytes
           ),
           !cached.isStale {
            try Task.checkCancellation()
            await cacheReadBarrierForTesting?()
            try ensureCurrent(requestLease)
            do {
                try BoundedHTTPPayload.validateCachedData(
                    cached.data,
                    allowedMediaTypes: policy.allowedMediaTypes,
                    maximumBytes: policy.maximumBytes,
                    imageLimits: policy.imageLimits
                )
                try Task.checkCancellation()
                try ensureCurrent(requestLease)
                return cached.data
            } catch {
                try ensureCurrent(requestLease)
                await FileCache.shared.remove { $0 == cacheKey }
                try ensureCurrent(requestLease)
            }
        }
        do {
            let lease = inflightTask(for: inflightKey) {
                try await self.executeData(request, policy: policy)
            }
            defer {
                releaseInflightTask(
                    for: inflightKey, waiterID: lease.waiterID, cancelIfLast: false
                )
            }
            let data = try await withTaskCancellationHandler {
                try await lease.task.value
            } onCancel: {
                self.releaseInflightTask(
                    for: inflightKey, waiterID: lease.waiterID, cancelIfLast: true
                )
            }
            try Task.checkCancellation()
            try ensureCurrent(requestLease)
            if cacheable,
               claimInflightCacheWrite(for: inflightKey, waiterID: lease.waiterID) {
                try await rememberSuccessfulGetResponse(
                    data, cacheKey: cacheKey, lease: requestLease
                )
                scheduleSuccessfulGetCache(
                    data, cacheKey: cacheKey, lease: requestLease
                )
            }
            return data
        } catch {
            guard cacheable,
                  isOfflineTransportError(error),
                  let cached = await FileCache.shared.get(
                      cacheKey,
                      maximumBytes: policy.maximumBytes
                  ) else { throw error }
            try Task.checkCancellation()
            try ensureCurrent(requestLease)
            do {
                try BoundedHTTPPayload.validateCachedData(
                    cached.data,
                    allowedMediaTypes: policy.allowedMediaTypes,
                    maximumBytes: policy.maximumBytes,
                    imageLimits: policy.imageLimits
                )
                try Task.checkCancellation()
                try ensureCurrent(requestLease)
                return cached.data
            } catch {
                try ensureCurrent(requestLease)
                await FileCache.shared.remove { $0 == cacheKey }
                try ensureCurrent(requestLease)
                throw error
            }
        }
    }

    /// Streams an authenticated response to a durable temporary file. This is
    /// intentionally separate from `downloadData`: large exports never need to
    /// reside in memory, while token refresh and login-generation checks remain
    /// identical to ordinary authenticated requests.
    func downloadToTemporaryFile(
        _ path: APIRequestPath,
        filename: String,
        maximumBytes: Int,
        allowedMediaTypes: Set<String>,
        queryItems: [URLQueryItem]? = nil,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let path = try Self.validatedRequestPath(path)
        let normalizedMediaTypes = Set(
            allowedMediaTypes.compactMap(BoundedHTTPPayload.normalizedMediaType)
        )
        guard maximumBytes > 0, !normalizedMediaTypes.isEmpty else {
            throw APIError.decodingError(BoundedHTTPPayload.ValidationError.invalidResponse)
        }
        let request = try buildRequest(
            path: path,
            method: "GET",
            queryItems: queryItems
        )
        return try await executeDownload(
            request,
            path: path,
            filename: filename,
            maximumBytes: maximumBytes,
            allowedMediaTypes: normalizedMediaTypes,
            fileManager: fileManager,
            isRetry: false
        )
    }

    /// Releases the exact UUID-scoped directory returned by
    /// `downloadToTemporaryFile`. Cleanup runs off-main, is restricted to this
    /// client's transfer root, and remains covered by interrupted-transfer
    /// reconciliation if removal fails.
    func releaseTemporaryDownload(_ fileURL: URL) async {
        let root = transferTemporaryRoot.standardizedFileURL
        let file = fileURL.standardizedFileURL
        let directory = file.deletingLastPathComponent()
        await Task.detached(priority: .utility) {
            let name = directory.lastPathComponent
            let id = name.hasPrefix("download-")
                ? String(name.dropFirst("download-".count))
                : ""
            guard directory.deletingLastPathComponent() == root,
                  UUID(uuidString: id) != nil,
                  file.deletingLastPathComponent() == directory else {
                Self.logger.fault(
                    "Refused to release a path outside the exact HausKlar download namespace."
                )
                return
            }
            Self.removeTemporaryTransferBestEffort(
                directory,
                fileManager: .default,
                context: "completed download consumer"
            )
        }.value
    }

    private func executeDownload(
        _ request: URLRequest,
        path: String,
        filename: String,
        maximumBytes: Int,
        allowedMediaTypes: Set<String>,
        fileManager: FileManager,
        isRetry: Bool
    ) async throws -> URL {
        let transport = try await transportDownloadResponse(
            for: request,
            maximumBytes: maximumBytes,
            fileManager: fileManager
        )
        let temporaryURL = transport.temporaryURL
        let temporaryDirectory = transport.temporaryDirectory
        let httpResponse = transport.response
        var retainsCompletedDownload = false
        defer {
            if !retainsCompletedDownload {
                Self.removeTemporaryTransferBestEffort(
                    temporaryDirectory,
                    fileManager: fileManager,
                    context: "incomplete download"
                )
            }
        }
        if httpResponse.statusCode == 401,!isRetry,shouldAttemptTokenRefresh(for: request) {
            guard let expectedSession=sessionSnapshot(for: request) else { throw APIError.unauthorized }
            do { try await refreshAccessToken(expectedSession: expectedSession) }
            catch {
                if shouldDeliverAuthFailure(for: error) {
                    await deliverAuthFailureIfCurrent(expectedSession)
                }
                throw error
            }
            guard let token=accessToken(ifCurrent: expectedSession) else { throw APIError.unauthorized }
            var retry=request
            retry.setValue("Bearer \(token)",forHTTPHeaderField: "Authorization")
            guard sessionSnapshot(for: retry)?.key == expectedSession.key else { throw APIError.unauthorized }
            return try await executeDownload(
                retry,
                path: path,
                filename: filename,
                maximumBytes: maximumBytes,
                allowedMediaTypes: allowedMediaTypes,
                fileManager: fileManager,
                isRetry: true
            )
        }
        try validateStatusCode(httpResponse.statusCode,data: transport.errorData)
        try ensureCurrentSessionGeneration(for: request)

        let normalizedMediaType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedMediaType,
              allowedMediaTypes.contains(normalizedMediaType) else {
            throw APIError.serverError(
                statusCode: httpResponse.statusCode,
                message: "The download returned an unexpected file type."
            )
        }
        let declaredBytes = httpResponse.expectedContentLength
        guard declaredBytes == NSURLSessionTransferSizeUnknown
                || (declaredBytes >= 0 && declaredBytes <= Int64(maximumBytes)) else {
            throw APIError.serverError(
                statusCode: 413,
                message: "The download exceeds the allowed size."
            )
        }
        // This URL was inspected while the staging file was empty. Foundation
        // caches resource values on the URL value, so force a fresh stat after
        // the streaming handle has synchronized and closed.
        var completedTemporaryURL = temporaryURL
        completedTemporaryURL.removeAllCachedResourceValues()
        let values = try completedTemporaryURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let actualBytes = values.fileSize,
              actualBytes > 0,
              actualBytes <= maximumBytes else {
            throw APIError.serverError(
                statusCode: 413,
                message: "The download exceeds the allowed size."
            )
        }

        let safeName = Self.safeDownloadFilename(filename)
        do {
            let standardizedDirectory = temporaryDirectory.standardizedFileURL
            let destination = standardizedDirectory
                .appendingPathComponent(safeName, isDirectory: false)
                .standardizedFileURL
            guard destination.deletingLastPathComponent() == standardizedDirectory,
                  destination.lastPathComponent == safeName else {
                throw APIError.serverError(
                    statusCode: 500,
                    message: "The download filename is invalid."
                )
            }
            if destination != temporaryURL.standardizedFileURL {
                try fileManager.moveItem(at: temporaryURL,to: destination)
            }
            try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
            try ensureCurrentSessionGeneration(for: request)
            retainsCompletedDownload = true
            return destination
        } catch {
            if error is APIError || Self.isCancellation(error) { throw error }
            throw APIError.networkError(error)
        }
    }

    /// Accept a strict basename or fall back to a generated, non-hidden name
    /// while retaining only a short alphanumeric extension. The per-download
    /// UUID directory makes the fallback collision-free without trusting any
    /// server- or user-provided path component.
    static func safeDownloadFilename(_ filename: String) -> String {
        let invalidScalars = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        let isStrictBasename = !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.hasPrefix(".")
            && filename.utf8.count <= 180
            && filename.rangeOfCharacter(from: invalidScalars) == nil
            && URL(fileURLWithPath: filename).lastPathComponent == filename
        if isStrictBasename { return filename }

        let extensionCandidate = filename
            .split(separator: ".", omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .lowercased() ?? ""
        let safeExtension = extensionCandidate.count <= 10
            && !extensionCandidate.isEmpty
            && extensionCandidate.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        return safeExtension ? "download.\(extensionCandidate)" : "download"
    }

    private func transportDownloadResponse(
        for request: URLRequest,
        maximumBytes: Int,
        fileManager: FileManager
    ) async throws -> DownloadTransportResponse {
        let directory = transferTemporaryRoot
            .appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let temporaryURL = directory
            .appendingPathComponent("response.body", isDirectory: false)
            .standardizedFileURL
        do {
            guard directory.deletingLastPathComponent()
                    == transferTemporaryRoot.standardizedFileURL,
                  temporaryURL.deletingLastPathComponent() == directory,
                  !fileManager.fileExists(atPath: directory.path) else {
                throw BoundedHTTPPayload.ValidationError.invalidResponse
            }
            try LocalFileProtection.prepareDirectory(
                transferTemporaryRoot,
                fileManager: fileManager
            )
            try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
            try Data().write(to: temporaryURL, options: [.completeFileProtection])
            let fileValues = try temporaryURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard fileValues.isRegularFile == true,
                  fileValues.isSymbolicLink != true,
                  fileValues.fileSize == 0 else {
                throw BoundedHTTPPayload.ValidationError.invalidResponse
            }
            try LocalFileProtection.protectItem(at: temporaryURL, fileManager: fileManager)
        } catch {
            Self.removeTemporaryTransferBestEffort(
                directory,
                fileManager: fileManager,
                context: "failed download staging"
            )
            if error is APIError { throw error }
            throw APIError.networkError(error)
        }

        let taskID = UUID()
        let task = Task { [session, transportDelegate] () throws -> DownloadTransportResponse in
            do {
                let response = try await transportDelegate.fileResponse(
                    for: request,
                    to: temporaryURL,
                    in: session,
                    successMaximumBytes: maximumBytes,
                    errorMaximumBytes: Self.maximumErrorResponseBytes
                )
                if (200...299).contains(response.response.statusCode) {
                    guard response.fileURL == temporaryURL, response.data == nil else {
                        throw BoundedHTTPPayload.ValidationError.invalidResponse
                    }
                } else {
                    guard response.fileURL == nil, let errorData = response.data else {
                        throw BoundedHTTPPayload.ValidationError.invalidResponse
                    }
                    return DownloadTransportResponse(
                        temporaryURL: temporaryURL,
                        temporaryDirectory: directory,
                        errorData: errorData,
                        response: response.response
                    )
                }
                return DownloadTransportResponse(
                    temporaryURL: temporaryURL,
                    temporaryDirectory: directory,
                    errorData: nil,
                    response: response.response
                )
            } catch {
                if Self.isCancellation(error) { throw error }
                if error is APIError { throw error }
                if error is BoundedHTTPPayload.ValidationError {
                    throw APIError.decodingError(error)
                }
                throw APIError.networkError(error)
            }
        }
        inflightLock.withLock { inflightDownloads[taskID] = task }
        defer { _ = inflightLock.withLock { inflightDownloads.removeValue(forKey: taskID) } }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            Self.removeTemporaryTransferBestEffort(
                directory,
                fileManager: fileManager,
                context: "failed download transport"
            )
            throw error
        }
    }

    /// Performs a POST request and returns raw response data for manual decoding.
    func postData<B: Encodable>(
        _ path: APIRequestPath,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> Data {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        request.httpBody = try encodeJSON(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            return try await executeMutationDataOnline(request, path: path, isRetry: false)
        } catch {
            if try await enqueueOfflineNoResponse(request: request, path: path, transportError: error) {
                throw APIError.offlineQueued
            }
            throw error
        }
    }

    private func executeMutationDataOnline(
        _ request: URLRequest,
        path: String,
        isRetry: Bool
    ) async throws -> Data {
        let (data, response) = try await transportResponse(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if httpResponse.statusCode == 401 && !isRetry && shouldAttemptTokenRefresh(for: request) {
            guard let expectedSession = sessionSnapshot(for: request) else {
                throw APIError.unauthorized
            }
            try await refreshAccessToken(expectedSession: expectedSession)
            guard let token = accessToken(ifCurrent: expectedSession) else { throw APIError.unauthorized }
            var retryRequest = request
            retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard sessionSnapshot(for: retryRequest)?.key == expectedSession.key else {
                throw APIError.unauthorized
            }
            return try await executeMutationDataOnline(retryRequest, path: path, isRetry: true)
        }
        try validateStatusCode(httpResponse.statusCode, data: data)
        try ensureCurrentSessionGeneration(for: request)
        await invalidateGetCache(for: path)
        try ensureCurrentSessionGeneration(for: request)
        return data
    }

    /// Performs an authenticated JSON POST while preserving structured non-2xx bodies.
    /// Used by version-negotiated protocols such as Fitness sync. Authentication expiry
    /// still refreshes once, and every response remains bound to its login generation.
    func postHTTPResponse<B: Encodable>(
        _ path: APIRequestPath,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> APIHTTPResponse {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        request.httpBody = try encodeJSON(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await executeHTTPResponse(request, path: path)
    }

    private func executeHTTPResponse(
        _ request: URLRequest,
        path: String,
        isRetry: Bool = false
    ) async throws -> APIHTTPResponse {
        let (data, response) = try await transportResponse(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if httpResponse.statusCode == 401 && !isRetry && shouldAttemptTokenRefresh(for: request) {
            guard let expectedSession = sessionSnapshot(for: request) else { throw APIError.unauthorized }
            try await refreshAccessToken(expectedSession: expectedSession)
            guard let token = accessToken(ifCurrent: expectedSession) else { throw APIError.unauthorized }
            var retryRequest = request
            retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard sessionSnapshot(for: retryRequest)?.key == expectedSession.key else {
                throw APIError.unauthorized
            }
            return try await executeHTTPResponse(retryRequest, path: path, isRetry: true)
        }
        if httpResponse.statusCode == 401 { throw APIError.unauthorized }
        try ensureCurrentSessionGeneration(for: request)
        if (200...299).contains(httpResponse.statusCode) {
            await invalidateGetCache(for: path)
            try ensureCurrentSessionGeneration(for: request)
        }
        return APIHTTPResponse(statusCode: httpResponse.statusCode, data: data)
    }

    /// Performs a POST request with an encodable body expecting no response body (e.g. 204 No Content).
    func postNoResponse<B: Encodable>(
        _ path: APIRequestPath,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        request.httpBody = try encodeJSON(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            try await executeNoResponseOnline(request, path: path, isRetry: false)
        } catch {
            if try await enqueueOfflineNoResponse(request: request, path: path, transportError: error) {
                return
            }
            throw error
        }
    }

    /// Performs a PUT request with an encodable body and decodes the response.
    func put<T: Decodable, B: Encodable>(
        _ path: APIRequestPath,
        body: B,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(path: path, method: "PUT", queryItems: queryItems)
        request.httpBody = try encodeJSON(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request, path: path)
    }

    /// Performs a PATCH request with an encodable body and decodes the response.
    func patch<T: Decodable, B: Encodable>(
        _ path: APIRequestPath,
        body: B,
        queryItems: [URLQueryItem]? = nil,
        operationID: String? = nil
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        var request = try buildRequest(
            path: path,
            method: "PATCH",
            queryItems: queryItems,
            operationID: operationID
        )
        request.httpBody = try encodeJSON(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await execute(request, path: path)
    }

    /// Performs a DELETE request with no response body.
    func delete(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil
    ) async throws {
        let path = try Self.validatedRequestPath(path)
        let request = try buildRequest(path: path, method: "DELETE", queryItems: queryItems)
        do {
            try await executeNoResponseOnline(request, path: path, isRetry: false)
        } catch {
            if try await enqueueOfflineNoResponse(request: request, path: path, transportError: error) {
                return
            }
            throw error
        }
    }

    /// Performs a DELETE request and decodes a JSON response body.
    func deleteReturning<T: Decodable>(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> T {
        let path = try Self.validatedRequestPath(path)
        let request = try buildRequest(path: path, method: "DELETE", queryItems: queryItems)
        return try await execute(request, path: path)
    }

    // MARK: - Private Helpers

    /// Only routes required to establish/recover/revoke authentication may run
    /// without a device identity. All other writes, including authenticated
    /// `/auth/*` preferences/profile operations, require durable provenance.
    private static let clientIdentityExemptMutationRoutes: Set<String> = [
        "/auth/login",
        "/auth/apple",
        "/auth/refresh",
        "/auth/logout",
        "/auth/forgot-password",
        "/auth/reset-password",
    ]

    private static func permitsMutationWithoutClientIdentity(
        path: String,
        method: String
    ) -> Bool {
        guard method == "POST" else { return false }
        let route = path.components(separatedBy: "?").first ?? path
        return clientIdentityExemptMutationRoutes.contains(route)
    }

    /// Builds a URLRequest for the given path, method, and optional query items.
    private func buildRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem]? = nil,
        operationID: String? = nil
    ) throws -> URLRequest {
        // Establish one unambiguous HTTPS authority before touching identity,
        // credentials, operation IDs, or caller-provided request bodies.
        let url = try Self.canonicalAPIURL(
            baseURL: baseURL,
            path: path,
            queryItems: queryItems
        )
        let isMutation = ["POST", "PUT", "PATCH", "DELETE"].contains(method)
        let mutationIsExempt = isMutation
            && Self.permitsMutationWithoutClientIdentity(path: path, method: method)
        let requestClientId: String?
        if isMutation && !mutationIsExempt {
            // Resolve before constructing headers or allowing callers to encode a
            // body. Failure therefore cannot reach transport or any HTTP outbox.
            requestClientId = try requireClientId()
        } else {
            requestClientId = availableClientId
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("ios", forHTTPHeaderField: "X-HausKlar-Client")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        request.setValue(appVersion, forHTTPHeaderField: "X-HausKlar-App-Version")

        // Bind the request to one logical login, not merely to a token string.
        if let snapshot = currentSessionSnapshot() {
            request.setValue("Bearer \(snapshot.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(
                String(snapshot.generation),
                forHTTPHeaderField: Self.sessionGenerationHeader
            )
        }

        if let requestClientId {
            request.setValue(requestClientId, forHTTPHeaderField: "X-Client-Id")
        }
        if isMutation && !mutationIsExempt {
            if let operationID {
                guard UUID(uuidString: operationID) != nil else { throw APIError.invalidURL }
                request.setValue(operationID.lowercased(), forHTTPHeaderField: Self.operationIDHeader)
            } else {
                request.setValue(UUID().uuidString, forHTTPHeaderField: Self.operationIDHeader)
            }
        }

        return request
    }

    private static func canonicalAPIURL(
        baseURL: String,
        path: String,
        queryItems: [URLQueryItem]?
    ) throws -> URL {
        do {
            try APIRequestPath.validateStoredValue(path)
        } catch {
            throw APIError.invalidURL
        }
        guard baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseURL.isEmpty,
              !path.contains("\\"),
              !path.contains("\r"),
              !path.contains("\n"),
              path.hasPrefix("/"),
              !path.hasPrefix("//"),
              var base = URLComponents(string: baseURL),
              base.query == nil,
              base.fragment == nil,
              base.user == nil,
              base.password == nil,
              let parsedBaseURL = base.url,
              let origin = AuthenticatedRedirectPolicy.canonicalHTTPSOrigin(parsedBaseURL),
              let route = URLComponents(string: path),
              route.scheme == nil,
              route.host == nil,
              route.user == nil,
              route.password == nil,
              route.query == nil,
              route.fragment == nil else {
            throw APIError.invalidURL
        }

        // Re-emit the validated authority in canonical form. A configured
        // non-default HTTPS port is retained exactly; 443 uses its effective
        // default representation.
        base.scheme = "https"
        base.host = origin.host
        base.port = origin.port == 443 ? nil : origin.port
        base.user = nil
        base.password = nil
        base.query = nil
        base.fragment = nil

        var basePath = base.percentEncodedPath
        if basePath == "/" {
            basePath = ""
        } else if basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        base.percentEncodedPath = basePath + route.percentEncodedPath
        if let queryItems, !queryItems.isEmpty {
            base.queryItems = queryItems
        }

        guard let url = base.url,
              AuthenticatedRedirectPolicy.canonicalHTTPSOrigin(url) == origin else {
            throw APIError.invalidURL
        }
        return url
    }

    private func execute<T: Decodable>(_ request: URLRequest, path: String) async throws -> T {
        do {
            return try await executeOnline(request, path: path, isRetry: false)
        } catch {
            return try await enqueueOfflineMutation(
                request: request,
                path: path,
                transportError: error
            )
        }
    }

    private func executeNoResponseOnline(
        _ request: URLRequest,
        path: String,
        isRetry: Bool
    ) async throws {
        let (data, response) = try await transportResponse(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        if httpResponse.statusCode == 401 && !isRetry && shouldAttemptTokenRefresh(for: request) {
            guard let expectedSession = sessionSnapshot(for: request) else {
                throw APIError.unauthorized
            }
            try await refreshAccessToken(expectedSession: expectedSession)
            guard let token = accessToken(ifCurrent: expectedSession) else {
                throw APIError.unauthorized
            }
            var retry = request
            retry.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard sessionSnapshot(for: retry)?.key == expectedSession.key else {
                throw APIError.unauthorized
            }
            try await executeNoResponseOnline(retry, path: path, isRetry: true)
            return
        }
        try validateStatusCode(httpResponse.statusCode, data: data)
        try ensureCurrentSessionGeneration(for: request)
        await invalidateGetCache(for: path)
        try ensureCurrentSessionGeneration(for: request)
    }

    /// Executes the given request, handles 401 by refreshing the token and retrying once.
    private func executeOnline<T: Decodable>(_ request: URLRequest, path: String, isRetry: Bool) async throws -> T {
        // Capture dispatch authority synchronously. A later token rotation keeps
        // this logical-session lease valid, while logout or account replacement
        // invalidates its generation before any response can be published.
        let requestLease = try captureSessionLease(for: request)
        let data: Data
        let response: URLResponse

        (data, response) = try await transportResponse(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }

        // Handle 401 — attempt token refresh and retry
        if httpResponse.statusCode == 401 && !isRetry && shouldAttemptTokenRefresh(for: request) {
            guard let expectedSession = sessionSnapshot(for: request) else {
                throw APIError.unauthorized
            }
            do {
                try await refreshAccessToken(expectedSession: expectedSession)
            } catch {
                if shouldDeliverAuthFailure(for: error) {
                    await deliverAuthFailureIfCurrent(expectedSession)
                }
                throw error
            }
            guard let token = accessToken(ifCurrent: expectedSession) else {
                throw APIError.unauthorized
            }
            var retryRequest = request
            retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard sessionSnapshot(for: retryRequest)?.key == expectedSession.key else {
                throw APIError.unauthorized
            }
            return try await executeOnline(retryRequest, path: path, isRetry: true)
        }

        try validateStatusCode(httpResponse.statusCode, data: data)
        try ensureCurrent(requestLease)

        if request.httpMethod == "GET" {
            let key = try responseCacheKey(for: request, lease: requestLease)
            try await cacheSuccessfulGetResponse(
                data,
                cacheKey: key,
                lease: requestLease
            )
        } else {
            await invalidateGetCache(for: path)
            try ensureCurrent(requestLease)
        }

        do {
            let decoded = try decodeJSON(T.self, from: data)
            try ensureCurrent(requestLease)
            return decoded
        } catch {
            if !isCurrent(requestLease) {
                throw APIError.unauthorized
            }
            throw APIError.decodingError(error)
        }
    }

    private func executeData(
        _ request: URLRequest,
        policy: DownloadDataPolicy,
        isRetry: Bool = false
    ) async throws -> Data {
        let transport = try await transportDataResponse(
            for: request,
            successMaximumBytes: policy.maximumBytes
        )
        let httpResponse = transport.response
        if httpResponse.statusCode == 401 && !isRetry && shouldAttemptTokenRefresh(for: request) {
            guard let expectedSession = sessionSnapshot(for: request) else {
                throw APIError.unauthorized
            }
            try await refreshAccessToken(expectedSession: expectedSession)
            guard let token = accessToken(ifCurrent: expectedSession) else {
                throw APIError.unauthorized
            }
            var retryRequest = request
            retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard sessionSnapshot(for: retryRequest)?.key == expectedSession.key else {
                throw APIError.unauthorized
            }
            return try await executeData(retryRequest, policy: policy, isRetry: true)
        }
        if !(200...299).contains(httpResponse.statusCode) {
            try validateStatusCode(httpResponse.statusCode, data: transport.data)
        }
        try Task.checkCancellation()
        let data: Data
        do {
            data = try BoundedHTTPPayload.validateDownloadData(
                transport.data,
                response: httpResponse,
                allowedMediaTypes: policy.allowedMediaTypes,
                maximumBytes: policy.maximumBytes,
                imageLimits: policy.imageLimits
            )
        } catch let error as BoundedHTTPPayload.ValidationError {
            throw APIError.decodingError(error)
        } catch {
            throw APIError.decodingError(error)
        }
        try Task.checkCancellation()
        try ensureCurrentSessionGeneration(for: request)
        return data
    }

    /// Stores a successful authenticated GET only while the request's login
    /// generation is still authoritative. The post-write check closes the race
    /// where logout/account replacement purges the cache while this actor hop is
    /// waiting; a stale write is removed before it can be observed.
    func cacheSuccessfulGetResponse(
        _ data: Data,
        cacheKey: String,
        request: URLRequest
    ) async throws {
        let lease = try captureSuccessfulResponseLease(for: request)
        try await cacheSuccessfulGetResponse(data, cacheKey: cacheKey, lease: lease)
    }

    private func cacheSuccessfulGetResponse(
        _ data: Data,
        cacheKey: String,
        lease: RequestSessionLease
    ) async throws {
        try ensureCurrent(lease)
        await FileCache.shared.set(cacheKey, data: data)
        guard isCurrent(lease) else {
            await FileCache.shared.remove { $0 == cacheKey }
            throw APIError.unauthorized
        }
    }

    private func rememberSuccessfulGetResponse(
        _ data: Data,
        cacheKey: String,
        lease: RequestSessionLease
    ) async throws {
        try ensureCurrent(lease)
        await FileCache.shared.setMemory(cacheKey, data: data)
        guard isCurrent(lease) else {
            await FileCache.shared.remove { $0 == cacheKey }
            throw APIError.unauthorized
        }
    }

    private func scheduleSuccessfulGetCache(
        _ data: Data,
        cacheKey: String,
        lease: RequestSessionLease
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cacheSuccessfulGetResponse(
                    data, cacheKey: cacheKey, lease: lease
                )
            } catch APIError.unauthorized {
                // Account replacement deliberately rejects this stale write;
                // the authoritative session-transition purge already reconciles it.
                Self.logger.info(
                    "Skipped stale background cache publication after session replacement. Reconciliation: the session-transition purge remains authoritative."
                )
            } catch {
                Self.logger.error(
                    "Background cache publication failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next successful network read republishes the cache entry."
                )
            }
        }
    }

    private func isCacheableGetPath(_ path: String) -> Bool {
        let cleanPath = path.components(separatedBy: "?").first ?? path

        // Only everyday family records with an intentional offline contract use
        // this generic cache. Fitness has its typed GRDB store; Finance, auth,
        // assistant, sync and live integrations deliberately remain outside it.
        if cleanPath == "/family/settings/ha"
            || cleanPath == "/naps/active"
            || cleanPath.hasPrefix("/medicine/check/") {
            return false
        }
        let durablePrefixes = [
            "/briefing/dashboard", "/briefing/glance", "/dashboard", "/coordination",
            "/home/status", "/calendar", "/tasks", "/family", "/children", "/medicine",
            "/illness", "/naps", "/dog", "/routines", "/meals", "/grocery", "/birthdays",
            "/homework", "/presents", "/renewals", "/documents", "/cycles", "/onboarding",
            "/library", "/workspace",
        ]
        return durablePrefixes.contains { prefix in
            guard cleanPath.hasPrefix(prefix) else { return false }
            let boundary = cleanPath.dropFirst(prefix.count).first
            return boundary == nil || boundary == "/"
        }
    }

    /// Scope cached responses to both URL and authentication identity.
    func responseCacheKey(for request: URLRequest) throws -> String {
        let lease: RequestSessionLease
        // Compatibility probe for requests created before the generation header
        // became mandatory. Production requests always carry the strict lease.
        if request.value(forHTTPHeaderField: "Authorization") == nil {
            lease = RequestSessionLease(session: nil)
        } else if let strictLease = try? captureSessionLease(for: request) {
            lease = strictLease
        } else if let authorization = request.value(forHTTPHeaderField: "Authorization"),
                  let current = currentSessionSnapshot(),
                  authorization == "Bearer \(current.accessToken)" {
            // Test/legacy callers may construct a request without the private
            // generation header. Production requests always take the strict path.
            lease = RequestSessionLease(session: current)
        } else {
            guard let url = request.url?.absoluteString,
                  let authorization = request.value(forHTTPHeaderField: "Authorization") else {
                throw APIError.invalidURL
            }
            // Backward-compatible support for manually constructed requests in
            // tests. Requests built by APIClient always carry a strict lease.
            let scope = cacheIdentity ?? authorization
            let digest = SHA256.hash(data: Data(scope.utf8))
            return url + "#auth=" + Data(digest).base64EncodedString()
        }
        return try responseCacheKey(for: request, lease: lease)
    }

    private func responseCacheKey(
        for request: URLRequest,
        lease: RequestSessionLease
    ) throws -> String {
        guard let url = request.url?.absoluteString else {
            throw APIError.invalidURL
        }
        guard request.value(forHTTPHeaderField: "Authorization") != nil else {
            return url
        }
        guard let scope = lease.cacheScope else { throw APIError.unauthorized }
        let digest = SHA256.hash(data: Data(scope.utf8))
        return url + "#auth=" + Data(digest).base64EncodedString()
    }

    /// Cached GET URL paths that aggregate other resources and must be purged on any mutation.
    private static let aggregateCachePaths = ["/dashboard", "/coordination", "/briefing", "/home/status", "/sync"]

    /// Purges cached GETs for the mutated resource (first path component) plus aggregate paths.
    private func invalidateGetCache(for path: String) async {
        let normalized = path.hasPrefix("/") ? path : "/" + path
        guard let firstComponent = normalized.split(separator: "/").first else {
            await FileCache.shared.clear()
            return
        }
        let pathPrefixes = Self.aggregateCachePaths + ["/" + firstComponent]
        let urlPrefixes = pathPrefixes.map { baseURL + $0 }
        await FileCache.shared.remove { key in
            urlPrefixes.contains { prefix in
                guard key.hasPrefix(prefix) else { return false }
                let boundary = key.dropFirst(prefix.count).first
                return boundary == nil || boundary == "/" || boundary == "?" || boundary == "#"
            }
        }
        onMutationCommitted?()
    }

    /// Allows the offline replay service to invalidate the resource represented
    /// by a typed sync item after `/sync/push` commits it.
    func invalidateCachedResource(_ path: String) async {
        await invalidateGetCache(for: path)
    }

    private func inflightTask(
        for key: String,
        operation: @escaping @Sendable () async throws -> Data
    ) -> InflightLease {
        let waiterID = UUID()
        return inflightLock.withLock {
            if let existing = inflightRequests[key] {
                existing.waiterIDs.insert(waiterID)
                return InflightLease(
                    task: existing.task, waiterID: waiterID, isFirstWaiter: false
                )
            }
            let task = Task { try await operation() }
            inflightRequests[key] = InflightRequest(
                task: task, firstWaiterID: waiterID
            )
            return InflightLease(task: task, waiterID: waiterID, isFirstWaiter: true)
        }
    }

    private func claimInflightCacheWrite(for key: String, waiterID: UUID) -> Bool {
        inflightLock.withLock {
            guard let request = inflightRequests[key],
                  request.waiterIDs.contains(waiterID),
                  !request.cacheWriteClaimed else { return false }
            request.cacheWriteClaimed = true
            return true
        }
    }

    private func releaseInflightTask(
        for key: String,
        waiterID: UUID,
        cancelIfLast: Bool
    ) {
        let taskToCancel: Task<Data, Error>? = inflightLock.withLock {
            guard let request = inflightRequests[key],
                  request.waiterIDs.remove(waiterID) != nil else { return nil }
            guard request.waiterIDs.isEmpty else { return nil }
            inflightRequests[key] = nil
            return cancelIfLast ? request.task : nil
        }
        taskToCancel?.cancel()
    }

    /// Remove legacy UserDefaults cache entries from prior caching implementation.
    private static func cleanLegacyUserDefaultsCache() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("api.get.cache.") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Refresh should only run for requests that use bearer auth.
    /// Public auth routes like /auth/login return 401 for bad credentials and
    /// should surface that directly to the user.
    private func shouldAttemptTokenRefresh(for request: URLRequest) -> Bool {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else {
            return false
        }
        guard let path = request.url?.path else {
            return false
        }
        return path != "/api/auth/login" && path != "/api/auth/refresh"
    }

    /// Successful responses are bound to the logical login generation that
    /// created their request. Access-token rotation deliberately keeps the same
    /// generation, while logout, reauthentication and a replacement login bump it.
    /// Public requests without bearer authentication are not identity-bound.
    private func isCurrentSessionGeneration(for request: URLRequest) -> Bool {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else {
            return true
        }
        guard let generationValue = request.value(
            forHTTPHeaderField: Self.sessionGenerationHeader
        ), let requestGeneration = UInt64(generationValue) else { return false }
        return stateLock.withLock {
            currentSessionSnapshotLocked()?.generation == requestGeneration
        }
    }

    private func ensureCurrentSessionGeneration(for request: URLRequest) throws {
        guard isCurrentSessionGeneration(for: request) else {
            throw APIError.unauthorized
        }
    }

    private func captureSessionLease(for request: URLRequest) throws -> RequestSessionLease {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization") else {
            return RequestSessionLease(session: nil)
        }
        guard let generationValue = request.value(
            forHTTPHeaderField: Self.sessionGenerationHeader
        ), let generation = UInt64(generationValue) else {
            throw APIError.unauthorized
        }
        return try stateLock.withLock {
            guard let snapshot = currentSessionSnapshotLocked(),
                  snapshot.generation == generation,
                  authorization == "Bearer \(snapshot.accessToken)" else {
                throw APIError.unauthorized
            }
            return RequestSessionLease(session: snapshot)
        }
    }

    /// A response that has already succeeded remains authoritative across an
    /// access-token rotation within the same logical login. Dispatch and 401
    /// refresh paths still use `captureSessionLease`, which requires the exact
    /// current bearer token; publication uses the immutable generation instead.
    private func captureSuccessfulResponseLease(
        for request: URLRequest
    ) throws -> RequestSessionLease {
        guard request.value(forHTTPHeaderField: "Authorization") != nil else {
            return RequestSessionLease(session: nil)
        }
        guard let generationValue = request.value(
            forHTTPHeaderField: Self.sessionGenerationHeader
        ), let generation = UInt64(generationValue) else {
            throw APIError.unauthorized
        }
        return try stateLock.withLock {
            guard let snapshot = currentSessionSnapshotLocked(),
                  snapshot.generation == generation else {
                throw APIError.unauthorized
            }
            return RequestSessionLease(session: snapshot)
        }
    }

    private func isCurrent(_ lease: RequestSessionLease) -> Bool {
        guard let expected = lease.session else { return true }
        return stateLock.withLock {
            currentSessionSnapshotLocked()?.key == expected.key
        }
    }

    private func ensureCurrent(_ lease: RequestSessionLease) throws {
        guard isCurrent(lease) else { throw APIError.unauthorized }
    }

    /// An old request's 401 must never pick up a newer session's refresh token,
    /// including a logout/re-login of the same account.
    func sessionSnapshot(for request: URLRequest) -> SessionSnapshot? {
        guard let requestAuthorization = request.value(forHTTPHeaderField: "Authorization") else {
            return nil
        }
        guard let generationValue = request.value(
            forHTTPHeaderField: Self.sessionGenerationHeader
        ), let requestGeneration = UInt64(generationValue) else { return nil }
        return stateLock.withLock {
            guard let snapshot = currentSessionSnapshotLocked(),
                  snapshot.generation == requestGeneration,
                  requestAuthorization == "Bearer \(snapshot.accessToken)" else { return nil }
            return snapshot
        }
    }

    func currentSessionSnapshot() -> SessionSnapshot? {
        stateLock.withLock { currentSessionSnapshotLocked() }
    }

    func isCurrentSession(_ expected: SessionSnapshot) -> Bool {
        stateLock.withLock { currentSessionSnapshotLocked()?.key == expected.key }
    }

    private func accessToken(ifCurrent expected: SessionSnapshot) -> String? {
        stateLock.withLock {
            guard let current = currentSessionSnapshotLocked(), current.key == expected.key else {
                return nil
            }
            return current.accessToken
        }
    }

    func deliverAuthFailureIfCurrent(_ expected: SessionSnapshot) async {
        await MainActor.run {
            guard self.isCurrentSession(expected) else { return }
            self.onAuthFailure?(expected)
        }
    }

    private func shouldDeliverAuthFailure(for error: Error) -> Bool {
        guard !Self.isCancellation(error), let apiError = error as? APIError else {
            return false
        }
        return apiError.isAuthError
    }

    /// Validates an HTTP status code and throws an appropriate error for non-2xx codes.
    private func validateStatusCode(_ statusCode: Int, data: Data?) throws {
        switch statusCode {
        case 200...299:
            return
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404:
            throw APIError.notFound
        case 409:
            throw APIError.conflict
        default:
            var message: String?
            if let data {
                // Detail is an optional presentation enhancement. Malformed
                // bodies retain the typed status and generic server message.
                let detail = try? JSONDecoder().decode([String: String].self, from: data)
                message = detail?["detail"]
            }
            throw APIError.serverError(statusCode: statusCode, message: message)
        }
    }

    private struct RefreshRequest: Encodable {
        let refreshToken: String
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String
        let refreshToken: String
    }

    /// Attempts to refresh the access token using the stored refresh token.
    /// Uses a shared Task so concurrent 401 handlers wait for the single refresh.
    private func refreshAccessToken(expectedSession: SessionSnapshot) async throws {
        let task: Task<Void, Error> = stateLock.withLock {
            guard currentSessionSnapshotLocked()?.key == expectedSession.key else {
                return Task { throw APIError.unauthorized }
            }
            if let existing = refreshTask {
                guard refreshTaskSession == expectedSession.key else {
                    return Task { throw APIError.unauthorized }
                }
                return existing
            }
            let newTask = Task { [self] in
                defer { clearRefreshTask(session: expectedSession.key) }
                try await performTokenRefresh(expectedSession: expectedSession)
            }
            refreshTask = newTask
            refreshTaskSession = expectedSession.key
            return newTask
        }
        try await task.value
    }

    private func clearRefreshTask(session: SessionKey) {
        stateLock.withLock {
            guard refreshTaskSession == session else { return }
            refreshTask = nil
            refreshTaskSession = nil
        }
    }

    private func performTokenRefresh(expectedSession: SessionSnapshot) async throws {
        try stateLock.withLock {
            guard currentSessionSnapshotLocked()?.key == expectedSession.key,
                  cachedRefreshToken == expectedSession.refreshToken else {
                throw APIError.unauthorized
            }
        }

        var request = try buildRequest(path: "/auth/refresh", method: "POST")
        request.httpBody = try encodeJSON(
            RefreshRequest(refreshToken: expectedSession.refreshToken)
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Clear the auth header for the refresh request — it uses the refresh token in the body
        request.setValue(nil, forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await transportResponse(for: request)
        } catch where Self.isCancellation(error) {
            throw error
        } catch {
            // A timeout or offline transition does not invalidate a 90-day
            // refresh token. Preserve the normalized transport error so callers
            // can retry without logging out or deleting the session envelope.
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if [400, 401, 403].contains(httpResponse.statusCode) {
                throw APIError.tokenRefreshFailed
            }
            // Detail is optional; the status remains authoritative.
            let detail = try? JSONDecoder().decode([String: String].self, from: data)
            throw APIError.serverError(
                statusCode: httpResponse.statusCode,
                message: detail?["detail"]
            )
        }
        guard !data.isEmpty else {
            throw APIError.tokenRefreshFailed
        }

        do {
            let refreshResponse = try decodeJSON(RefreshResponse.self, from: data)
            let installed = installRefreshedTokens(
                accessToken: refreshResponse.accessToken,
                refreshToken: refreshResponse.refreshToken,
                expectedSession: expectedSession
            )
            guard installed else { throw APIError.unauthorized }
        } catch {
            if error is DecodingError {
                throw APIError.tokenRefreshFailed
            }
            throw error
        }
    }

    /// Atomically rotates tokens only if the response still belongs to the
    /// generation that started the refresh. Keychain writes share `stateLock`
    /// with login and clear, closing the stale-persistence race.
    @discardableResult
    func installRefreshedTokens(
        accessToken: String,
        refreshToken: String,
        expectedSession: SessionSnapshot
    ) -> Bool {
        stateLock.withLock {
            guard let current = currentSessionSnapshotLocked(),
                  current.key == expectedSession.key,
                  current.refreshToken == expectedSession.refreshToken else { return false }

            if requiresPersistedTokenRotation {
                do {
                    guard let envelope = try loadSessionEnvelope(),
                          envelope.identity == current.identity,
                          envelope.accessToken == current.accessToken,
                          envelope.refreshToken == current.refreshToken else { return false }
                    try saveSessionEnvelope(
                        StoredSessionEnvelope(
                            identity: envelope.identity,
                            accessToken: accessToken,
                            refreshToken: refreshToken,
                            userJSON: envelope.userJSON
                        )
                    )
                } catch {
                    Self.logger.error(
                        "Refusing in-memory token rotation after Keychain envelope failure: \(error.localizedDescription, privacy: .public)"
                    )
                    return false
                }
            }
            cachedAccessToken = accessToken
            cachedRefreshToken = refreshToken
            return true
        }
    }

    private func currentSessionSnapshotLocked() -> SessionSnapshot? {
        guard let identity = cachedCacheIdentity,
              let accessToken = cachedAccessToken,
              let refreshToken = cachedRefreshToken else { return nil }
        return SessionSnapshot(
            identity: identity,
            generation: credentialGeneration,
            accessToken: accessToken,
            refreshToken: refreshToken
        )
    }

    private func invalidateCredentialGenerationLocked() -> Task<Void, Error>? {
        credentialGeneration &+= 1
        let task = refreshTask
        refreshTask = nil
        refreshTaskSession = nil
        return task
    }

}
