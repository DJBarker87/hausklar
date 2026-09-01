import CryptoKit
import Darwin
import Foundation
import os

struct SharedCapturePayload: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let text: String?
    let filePath: String?
    let ownerIdentity: String?
    let createdAt: Date
    let originalFilename: String?
    let mediaType: String?
    let byteCount: Int

    init(
        id: String,
        text: String?,
        filePath: String?,
        ownerIdentity: String? = nil,
        createdAt: Date = Date(),
        originalFilename: String? = nil,
        mediaType: String? = nil,
        byteCount: Int = 0
    ) {
        self.id = id
        self.text = text
        self.filePath = filePath
        self.ownerIdentity = ownerIdentity
        self.createdAt = createdAt
        self.originalFilename = originalFilename
        self.mediaType = mediaType
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, filePath, ownerIdentity, createdAt, originalFilename, mediaType, byteCount
    }

    /// Older app versions stored only id/text/filePath in UserDefaults. Keeping
    /// decoding tolerant lets the filesystem migration adopt those entries once.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        filePath = try values.decodeIfPresent(String.self, forKey: .filePath)
        ownerIdentity = try values.decodeIfPresent(String.self, forKey: .ownerIdentity)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        originalFilename = try values.decodeIfPresent(String.self, forKey: .originalFilename)
        mediaType = try values.decodeIfPresent(String.self, forKey: .mediaType)
        byteCount = try values.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
    }
}

struct SharedCaptureClaim: Identifiable, Equatable, Sendable {
    var id: String { leaseID }
    let leaseID: String
    let expiresAt: Date
    let payload: SharedCapturePayload
    fileprivate let claimedDirectoryPath: String
}

struct SharedCaptureRecoveryItem: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case ready
        case claimed
    }

    let id: String
    let ownerIdentity: String?
    let createdAt: Date
    let byteCount: Int
    let state: State
}

struct SharedCaptureReconciliation: Equatable, Sendable {
    var releasedExpiredClaims = 0
    var removedTemporaryItems = 0
    var removedInvalidItems = 0
    var removedOrphanAssets = 0
    var migratedLegacyItems = 0
}

enum SharedCaptureStoreError: LocalizedError, Equatable {
    case containerUnavailable
    case coordinationFailed
    case emptyPayload
    case textTooLong
    case fileTooLarge
    case unsupportedFile
    case invalidFilename
    case invalidMediaType
    case inboxFull
    case staleClaim
    case corruptItem
    case cleanupFailed
    case accountBoundaryChanged

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            "HausKlar could not open its secure shared inbox."
        case .coordinationFailed:
            "The shared inbox is busy. Please try again."
        case .emptyPayload:
            "That shared item is empty."
        case .textTooLong:
            "Shared text is too long. Keep it under 10,000 characters."
        case .fileTooLarge:
            "That file is too large to share with HausKlar."
        case .unsupportedFile:
            "Only PDF, image and text documents can be shared with HausKlar."
        case .invalidFilename:
            "That file name is not safe to store."
        case .invalidMediaType:
            "That shared file type is not valid."
        case .inboxFull:
            "HausKlar's shared inbox is full. Open the app and review waiting items first."
        case .staleClaim:
            "That shared item was recovered for a later review."
        case .corruptItem:
            "That shared item could not be verified."
        case .cleanupFailed:
            "HausKlar could not securely clean an interrupted shared item."
        case .accountBoundaryChanged:
            "Your HausKlar account changed while this item was being prepared. Please share it again."
        }
    }
}

/// A crash-safe, cross-process inbox shared by the app and its share extension.
///
/// Producers reserve a protected item in `temporary`, populate only that exact
/// directory outside the lock, then publish it with one same-volume rename. A
/// durable owner/epoch record prevents pre-boundary work from publishing after an
/// account change or purge. Consumers claim with another atomic rename. A small
/// POSIX advisory lock serialises both processes; a process-local lock complements
/// it because POSIX record locks do not serialize threads in the same process.
enum SharedCaptureStore {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "SharedCaptureStore"
    )

    struct Limits: Equatable, Sendable {
        var maximumItems = 20
        var maximumTotalBytes = 256 * 1_024 * 1_024
        var maximumFileBytes = 64 * 1_024 * 1_024
        var maximumTextCharacters = 10_000
        var maximumFilenameCharacters = 240
        var maximumMediaTypeCharacters = 127
        var claimLifetime: TimeInterval = 60 * 60
        var temporaryLifetime: TimeInterval = 60 * 60
        var maximumReconciliationCandidates = 128
        var maximumReconciliationMutations = 32
    }

    struct Context {
        let containerURL: URL
        let defaults: UserDefaults?
        let fileManager: FileManager
        let limits: Limits
        /// A deterministic race seam used by the store's concurrency tests. It
        /// runs after a protected stage is reserved and coordination is released.
        let producerBoundaryDidResolve: (() -> Void)?

        init(
            containerURL: URL,
            defaults: UserDefaults? = nil,
            fileManager: FileManager = .default,
            limits: Limits = Limits(),
            producerBoundaryDidResolve: (() -> Void)? = nil
        ) {
            self.containerURL = containerURL
            self.defaults = defaults
            self.fileManager = fileManager
            self.limits = limits
            self.producerBoundaryDidResolve = producerBoundaryDidResolve
        }
    }

    static let suiteName =
        (Bundle.main.object(forInfoDictionaryKey: "HausKlarAppGroup") as? String)
        ?? "group.org.example.hausklar"
    static let queueKey = "hausklar.sharedCaptureQueue"
    static let activeIdentityKey = "hausklar.activeCaptureIdentity"
    static let directoryName = "SharedCaptureInbox-v2"
    static let legacyDirectoryName = "SharedCapture"
    static let readyDirectoryName = "ready"
    static let claimedDirectoryName = "claimed"
    static let temporaryDirectoryName = "temporary"

    private static let metadataFilename = "metadata.json"
    private static let reservationLeaseFilename = ".producer-lease"
    private static let migrationMarkerFilename = ".legacy-userdefaults-migrated"
    private static let lockFilename = ".SharedCaptureInbox-v2.lock"
    private static let boundaryStateFilename = ".SharedCaptureInbox-v2.boundary"
    private static let claimMarker = ".claim."
    private static let itemSuffix = ".item"
    private static let maximumMetadataBytes = 256 * 1_024
    private static let maximumLegacyQueueBytes = 1 * 1_024 * 1_024
    private static let maximumBoundaryStateBytes = 16 * 1_024
    private static let maximumIdentityCharacters = 512
    private static let maximumQuotaEntriesExamined = 1_024
    private static let copyChunkBytes = 1 * 1_024 * 1_024
    private static let processCoordinationLock = NSLock()
    /// SAFETY: every access to the process-local live-reservation set is guarded
    /// by `lock`; the cross-process half of the lease is a held POSIX file lock.
    private final class LiveReservationRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func insert(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.insert(path).inserted
        }

        func contains(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.contains(path)
        }

        func remove(_ path: String) {
            lock.lock()
            paths.remove(path)
            lock.unlock()
        }
    }

    private static let liveReservationRegistry = LiveReservationRegistry()
    /// This store is compiled into both the app and the share extension, so it
    /// cannot depend on the app-only `ISODateParser`. The formatter instances
    /// are mutable reference types; one lock-protected codec keeps fractional
    /// FIFO precision while remaining safe under concurrent extension writes.
    private final class TimestampCodec: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter
        private let legacy: ISO8601DateFormatter

        init() {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fractional = fractional

            let legacy = ISO8601DateFormatter()
            legacy.formatOptions = [.withInternetDateTime]
            self.legacy = legacy
        }

        func string(from date: Date) -> String {
            lock.lock()
            defer { lock.unlock() }
            return fractional.string(from: date)
        }

        func date(from value: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: value) ?? legacy.date(from: value)
        }
    }

    private static let timestampCodec = TimestampCodec()
    private static let supportedExtensions: Set<String> = [
        "pdf", "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "txt",
    ]

    private struct StoredItem: Codable, Equatable {
        enum Kind: String, Codable {
            case text
            case file
        }

        let version: Int
        let id: String
        let kind: Kind
        let text: String?
        let assetFilename: String?
        let originalFilename: String?
        let mediaType: String?
        let byteCount: Int
        let createdAt: Date
        var ownerIdentity: String?
    }

    private struct ItemLocation {
        let directory: URL
        let item: StoredItem
        let state: SharedCaptureRecoveryItem.State
    }

    private struct ProducerBoundary {
        let ownerIdentity: String?
        let epoch: UUID
    }

    private struct ProducerReservation {
        let boundary: ProducerBoundary
        let item: StoredItem
        let directory: URL
        let lease: ReservationLease
    }

    private final class ReservationLease {
        private let lock = NSLock()
        private let directoryPath: String
        private var descriptor: Int32?

        init(directoryPath: String, descriptor: Int32) {
            self.directoryPath = directoryPath
            self.descriptor = descriptor
        }

        func release() {
            lock.lock()
            guard let descriptor else {
                lock.unlock()
                return
            }
            self.descriptor = nil
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
            SharedCaptureStore.liveReservationRegistry.remove(directoryPath)
            lock.unlock()
        }

        deinit {
            release()
        }
    }

    private struct BoundaryState: Codable {
        let version: Int
        let epoch: UUID
        let ownerIdentity: String?
    }

    private struct LegacyStoredEntry {
        let item: StoredItem
        let sourceFile: URL?
    }

    private struct LegacyQuotaExclusion {
        let index: Int
        let item: StoredItem
    }

    private struct ReconciliationBudget {
        let maximumCandidatesPerDirectory: Int
        let maximumMutations: Int
        var mutations = 0

        var hasMutationCapacity: Bool { mutations < maximumMutations }

        mutating func recordMutation() {
            mutations += 1
        }

        mutating func recordMutations(_ count: Int) {
            mutations = min(maximumMutations,mutations + max(0,count))
        }
    }

    private enum QuotaLocationKind: Equatable {
        case ready
        case claimed
        case reservation
    }

    // MARK: - Identity boundary

    static func setActiveIdentity(
        _ identity: String,
        context: Context? = nil
    ) throws {
        guard isValidIdentity(identity) else {
            throw SharedCaptureStoreError.accountBoundaryChanged
        }
        let context = try resolvedContext(context)
        try withCoordination(context) {
            let current = try currentBoundaryStateLocked(context)
            if current.ownerIdentity != identity {
                _ = try rotateBoundaryStateLocked(ownerIdentity: identity, context: context)
            }
            // UserDefaults remains a backwards-compatible display mirror. The
            // durable boundary file is the cross-process source of truth.
            context.defaults?.set(identity, forKey: activeIdentityKey)
        }
    }

    static func clearActiveIdentity(context: Context? = nil) throws {
        let context = try resolvedContext(context)
        try withCoordination(context) {
            _ = try rotateBoundaryStateLocked(ownerIdentity: nil, context: context)
            context.defaults?.removeObject(forKey: activeIdentityKey)
        }
    }

    static func activeIdentity(context: Context? = nil) -> String? {
        // This is a display-only, fail-closed probe. Mutating producer paths use
        // `reserveProducerStage`, which propagates coordination failures.
        guard let context = try? resolvedContext(context) else { return nil }
        return try? withCoordination(context) {
            try currentBoundaryStateLocked(context).ownerIdentity
        }
    }

    // MARK: - Producer API

    @discardableResult
    static func enqueueText(
        _ text: String,
        ownerIdentity: String? = nil,
        context: Context? = nil,
        now: Date = Date()
    ) throws -> String {
        let context = try resolvedContext(context)
        try validateOperationDate(now, context: context)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SharedCaptureStoreError.emptyPayload }
        guard trimmed.count <= context.limits.maximumTextCharacters else {
            throw SharedCaptureStoreError.textTooLong
        }
        let reservation = try reserveProducerStage(
            explicitIdentity: ownerIdentity,
            context: context,
            now: now
        ) { identity in
            StoredItem(
                version: 2,
                id: UUID().uuidString.lowercased(),
                kind: .text,
                text: trimmed,
                assetFilename: nil,
                originalFilename: nil,
                mediaType: "text/plain",
                byteCount: trimmed.lengthOfBytes(using: .utf8),
                createdAt: now,
                ownerIdentity: identity
            )
        }
        return try finishProducerReservation(
            reservation,
            sourceFile: nil,
            data: nil,
            context: context,
            now: now
        )
    }

    @discardableResult
    static func enqueueFile(
        at sourceURL: URL,
        originalFilename: String? = nil,
        mediaType: String? = nil,
        ownerIdentity: String? = nil,
        context: Context? = nil,
        now: Date = Date()
    ) throws -> String {
        let context = try resolvedContext(context)
        try validateOperationDate(now, context: context)
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let values = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SharedCaptureStoreError.unsupportedFile
        }
        let byteCount = values.fileSize ?? 0
        guard byteCount > 0 else { throw SharedCaptureStoreError.emptyPayload }
        guard byteCount <= context.limits.maximumFileBytes else {
            throw SharedCaptureStoreError.fileTooLarge
        }
        let filename = try validatedFilename(
            originalFilename ?? values.name ?? sourceURL.lastPathComponent,
            limits: context.limits
        )
        let validatedType = try validatedMediaType(mediaType, filename: filename, limits: context.limits)
        let reservation = try reserveProducerStage(
            explicitIdentity: ownerIdentity,
            context: context,
            now: now
        ) { identity in
            makeFileItem(
                filename: filename,
                mediaType: validatedType,
                byteCount: byteCount,
                ownerIdentity: identity,
                now: now
            )
        }
        return try finishProducerReservation(
            reservation,
            sourceFile: sourceURL,
            data: nil,
            context: context,
            now: now
        )
    }

    @discardableResult
    static func enqueueFileData(
        _ data: Data,
        originalFilename: String,
        mediaType: String,
        ownerIdentity: String? = nil,
        context: Context? = nil,
        now: Date = Date()
    ) throws -> String {
        let context = try resolvedContext(context)
        try validateOperationDate(now, context: context)
        guard !data.isEmpty else { throw SharedCaptureStoreError.emptyPayload }
        guard data.count <= context.limits.maximumFileBytes else {
            throw SharedCaptureStoreError.fileTooLarge
        }
        let filename = try validatedFilename(originalFilename, limits: context.limits)
        let validatedType = try validatedMediaType(mediaType, filename: filename, limits: context.limits)
        let reservation = try reserveProducerStage(
            explicitIdentity: ownerIdentity,
            context: context,
            now: now
        ) { identity in
            makeFileItem(
                filename: filename,
                mediaType: validatedType,
                byteCount: data.count,
                ownerIdentity: identity,
                now: now
            )
        }
        return try finishProducerReservation(
            reservation,
            sourceFile: nil,
            data: data,
            context: context,
            now: now
        )
    }

    // MARK: - Consumer API

    static func claimNext(
        for identity: String,
        context: Context? = nil,
        now: Date = Date()
    ) throws -> SharedCaptureClaim? {
        let context = try resolvedContext(context)
        try validateOperationDate(now, context: context)
        let requestedExpiry = now.addingTimeInterval(context.limits.claimLifetime)
        try validateTimestampDate(requestedExpiry)
        return try withCoordination(context) {
            guard isValidIdentity(identity),
                  try currentBoundaryStateLocked(context).ownerIdentity == identity else {
                return nil
            }
            _ = try prepareAndReconcileLocked(context: context, now: now)
            let ready = try validItems(in: readyDirectory(context), state: .ready, context: context)
                .sorted(by: oldestFirst)
            guard let candidate = ready.first(where: {
                $0.item.ownerIdentity == nil || $0.item.ownerIdentity == identity
            }) else { return nil }

            let leaseID = UUID().uuidString.lowercased()
            let encodedClaim = try claimName(
                readyName: candidate.directory.lastPathComponent,
                expiresAt: requestedExpiry,
                leaseID: leaseID
            )
            let destination = claimedDirectory(context).appendingPathComponent(
                encodedClaim.name,
                isDirectory: true
            )
            try atomicRename(candidate.directory, destination)

            var claimedItem = candidate.item
            if claimedItem.ownerIdentity == nil {
                claimedItem.ownerIdentity = identity
                do {
                    try writeMetadata(claimedItem, to: destination, context: context)
                } catch let metadataError {
                    do {
                        try atomicRename(destination, candidate.directory)
                    } catch {
                        logger.error(
                            "Claim metadata failed and rollback could not publish the item back to ready: \(error.localizedDescription, privacy: .public). Reconciliation: the bounded expired-claim pass retains and retries this claimed item."
                        )
                        throw SharedCaptureStoreError.coordinationFailed
                    }
                    throw metadataError
                }
            }
            let payload = try payload(for: claimedItem, in: destination, context: context)
            return SharedCaptureClaim(
                leaseID: leaseID,
                expiresAt: encodedClaim.expiresAt,
                payload: payload,
                claimedDirectoryPath: destination.path
            )
        }
    }

    /// Deletes only the directory held by this exact lease. A recovered/reclaimed
    /// copy with a newer lease can therefore never be removed by a late callback.
    static func acknowledge(
        _ claim: SharedCaptureClaim,
        context: Context? = nil
    ) throws {
        let context = try resolvedContext(context)
        try withCoordination(context) {
            let directory = try verifiedClaimDirectory(claim, context: context)
            guard context.fileManager.fileExists(atPath: directory.path) else {
                throw SharedCaptureStoreError.staleClaim
            }
            let item = try readAndValidateItem(at: directory, context: context)
            guard item.id == claim.payload.id else { throw SharedCaptureStoreError.staleClaim }
            try context.fileManager.removeItem(at: directory)
        }
    }

    /// Makes an uncommitted handoff immediately available again. Returns false if
    /// the lease had already expired/recovered or was previously acknowledged.
    @discardableResult
    static func release(
        _ claim: SharedCaptureClaim,
        context: Context? = nil
    ) throws -> Bool {
        let context = try resolvedContext(context)
        return try withCoordination(context) {
            let directory = try verifiedClaimDirectory(claim, context: context)
            guard context.fileManager.fileExists(atPath: directory.path) else { return false }
            let item = try readAndValidateItem(at: directory, context: context)
            guard item.id == claim.payload.id,
                  let readyName = readyName(fromClaimedName: directory.lastPathComponent) else {
                throw SharedCaptureStoreError.staleClaim
            }
            let destination = readyDirectory(context).appendingPathComponent(readyName, isDirectory: true)
            guard !context.fileManager.fileExists(atPath: destination.path) else {
                throw SharedCaptureStoreError.coordinationFailed
            }
            try atomicRename(directory, destination)
            return true
        }
    }

    // Compatibility is intentionally claim-based: callers must explicitly ack or
    // release rather than destructively popping metadata before durable handoff.
    @available(*, unavailable, message: "Use claimNext(for:) and acknowledge/release the lease")
    static func takeNext() -> SharedCapturePayload? { nil }

    // MARK: - Recovery, inspection and purge

    @discardableResult
    static func reconcile(
        context: Context? = nil,
        now: Date = Date()
    ) throws -> SharedCaptureReconciliation {
        let context = try resolvedContext(context)
        try validateOperationDate(now, context: context)
        return try withCoordination(context) {
            try prepareAndReconcileLocked(context: context, now: now)
        }
    }

    static func recoveryItems(
        context: Context? = nil,
        now: Date = Date()
    ) throws -> [SharedCaptureRecoveryItem] {
        let context = try resolvedContext(context)
        try validateOperationDate(now, context: context)
        return try withCoordination(context) {
            _ = try prepareAndReconcileLocked(context: context, now: now)
            let ready = try validItems(in: readyDirectory(context), state: .ready, context: context)
            let claimed = try validItems(in: claimedDirectory(context), state: .claimed, context: context)
            return (ready + claimed).sorted(by: oldestFirst).map {
                SharedCaptureRecoveryItem(
                    id: $0.item.id,
                    ownerIdentity: $0.item.ownerIdentity,
                    createdAt: $0.item.createdAt,
                    byteCount: $0.item.byteCount,
                    state: $0.state
                )
            }
        }
    }

    /// Removes metadata and assets together at an authorised account boundary.
    /// Coordination and boundary files live beside the inbox, so they remain
    /// valid while its data directories are removed under the cross-process lock.
    static func purge(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) throws {
        // The durable epoch is authoritative. Clearing only the compatibility
        // defaults would falsely report a completed purge while leaving an old
        // boundary and private inbox able to reappear when the App Group mounts.
        guard let containerURL else { throw SharedCaptureStoreError.containerUnavailable }
        let context = Context(containerURL: containerURL, defaults: defaults, fileManager: fileManager)
        try withCoordination(context) {
            // Rotate before touching identity or inbox data. Once purge returns,
            // no producer that resolved under the previous account boundary can
            // publish, even if its large file copy began before this lock.
            _ = try rotateBoundaryStateLocked(ownerIdentity: nil, context: context)
            defaults?.removeObject(forKey: queueKey)
            defaults?.removeObject(forKey: activeIdentityKey)
            for name in [directoryName, legacyDirectoryName] {
                let directory = containerURL.appendingPathComponent(name, isDirectory: true)
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
            }
        }
    }

    // MARK: - Staging and publication

    private static func makeFileItem(
        filename: String,
        mediaType: String,
        byteCount: Int,
        ownerIdentity: String?,
        now: Date,
        id: String = UUID().uuidString.lowercased()
    ) -> StoredItem {
        let fileExtension = preferredExtension(filename: filename, mediaType: mediaType)
        return StoredItem(
            version: 2,
            id: id,
            kind: .file,
            text: nil,
            assetFilename: "asset.\(fileExtension)",
            originalFilename: filename,
            mediaType: mediaType,
            byteCount: byteCount,
            createdAt: now,
            ownerIdentity: ownerIdentity
        )
    }

    private static func reserveProducerStage(
        explicitIdentity: String?,
        context: Context,
        now: Date,
        makeItem: (String?) -> StoredItem
    ) throws -> ProducerReservation {
        let reservation = try withCoordination(context) {
            _ = try prepareAndReconcileLocked(context: context, now: now)
            let state = try currentBoundaryStateLocked(context)
            if let explicitIdentity {
                guard isValidIdentity(explicitIdentity),
                      state.ownerIdentity == explicitIdentity else {
                    throw SharedCaptureStoreError.accountBoundaryChanged
                }
            }
            let boundary = ProducerBoundary(
                ownerIdentity: explicitIdentity ?? state.ownerIdentity,
                epoch: state.epoch
            )
            let item = makeItem(boundary.ownerIdentity)
            try assertCapacityLocked(
                for: item,
                excludingTemporary: nil,
                excludingLegacy: nil,
                context: context,
                now: now
            )
            let directory = try reserveStageLocked(item: item, context: context)
            let lease: ReservationLease
            do {
                lease = try acquireReservationLeaseLocked(
                    for: directory,
                    context: context
                )
            } catch let leaseError {
                do {
                    try context.fileManager.removeItem(at: directory)
                } catch {
                    logger.error(
                        "Failed to remove a capture reservation whose live lease could not be acquired: \(error.localizedDescription, privacy: .public)"
                    )
                    throw SharedCaptureStoreError.cleanupFailed
                }
                throw leaseError
            }
            return ProducerReservation(
                boundary: boundary,
                item: item,
                directory: directory,
                lease: lease
            )
        }
        context.producerBoundaryDidResolve?()
        return reservation
    }

    private static func reserveStageLocked(item: StoredItem, context: Context) throws -> URL {
        let root = temporaryDirectory(context).standardizedFileURL
        let directory = root.appendingPathComponent(
            "stage-\(item.id)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard isDirectChild(directory, of: root),
              isTemporaryStageName(directory.lastPathComponent) else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        try context.fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        do {
            guard isSafeDirectory(directory) else {
                throw SharedCaptureStoreError.coordinationFailed
            }
            try protect(directory, fileManager: context.fileManager)
            try writeMetadata(item, to: directory, context: context)
            return directory
        } catch let reservationError {
            do {
                try context.fileManager.removeItem(at: directory)
            } catch {
                logger.error(
                    "Failed to remove an incomplete capture reservation: \(error.localizedDescription, privacy: .public). Reconciliation: the bounded temporary-item pass retries this UUID-owned stage."
                )
                throw SharedCaptureStoreError.cleanupFailed
            }
            throw reservationError
        }
    }

    private static func finishProducerReservation(
        _ reservation: ProducerReservation,
        sourceFile: URL?,
        data: Data?,
        context: Context,
        now: Date
    ) throws -> String {
        defer { reservation.lease.release() }
        do {
            try withCoordination(context) {
                guard try currentBoundaryStateLocked(context).epoch
                        == reservation.boundary.epoch else {
                    throw SharedCaptureStoreError.accountBoundaryChanged
                }
            }
            try populateReservedStage(
                item: reservation.item,
                sourceFile: sourceFile,
                data: data,
                directory: reservation.directory,
                context: context
            )
            return try publish(
                staged: reservation.directory,
                item: reservation.item,
                boundary: reservation.boundary,
                context: context,
                now: now
            )
        } catch let operationError {
            do {
                try removeReservedStageIfPresent(reservation.directory, context: context)
            } catch {
                logger.error(
                    "Failed to remove an unpublished capture reservation: \(error.localizedDescription, privacy: .public). Reconciliation: the bounded temporary-item pass retries this UUID-owned stage."
                )
                throw SharedCaptureStoreError.cleanupFailed
            }
            throw operationError
        }
    }

    private static func acquireReservationLeaseLocked(
        for directory: URL,
        context: Context
    ) throws -> ReservationLease {
        let leaseURL = directory.appendingPathComponent(reservationLeaseFilename)
        let descriptor = leaseURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(
                path,
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        do {
            try protect(leaseURL, fileManager: context.fileManager)
            while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
                guard errno == EINTR else {
                    throw SharedCaptureStoreError.coordinationFailed
                }
            }
            let path = directory.standardizedFileURL.path
            guard liveReservationRegistry.insert(path) else {
                throw SharedCaptureStoreError.coordinationFailed
            }
            return ReservationLease(directoryPath: path, descriptor: descriptor)
        } catch let leaseError {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            Darwin.close(descriptor)
            do {
                if try pathEntryExists(leaseURL) {
                    try context.fileManager.removeItem(at: leaseURL)
                }
            } catch {
                logger.error(
                    "Failed to clean an unusable capture reservation lease: \(error.localizedDescription, privacy: .public)"
                )
                throw SharedCaptureStoreError.cleanupFailed
            }
            throw leaseError
        }
    }

    /// Populates only the exact directory reserved under coordination. It never
    /// recreates that directory if purge unlinks it during an out-of-lock copy.
    private static func populateReservedStage(
        item: StoredItem,
        sourceFile: URL?,
        data: Data?,
        directory: URL,
        context: Context
    ) throws {
        let root = temporaryDirectory(context).standardizedFileURL
        guard isDirectChild(directory, of: root),
              isTemporaryStageName(directory.lastPathComponent),
              isSafeDirectory(directory) else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        if let assetFilename = item.assetFilename {
            let destination = directory.appendingPathComponent(assetFilename, isDirectory: false)
            if let sourceFile {
                try copyExactFile(
                    from: sourceFile,
                    to: destination,
                    expectedBytes: item.byteCount,
                    context: context
                )
            } else if let data {
                guard data.count == item.byteCount else {
                    throw SharedCaptureStoreError.corruptItem
                }
                try data.write(to: destination, options: [.completeFileProtection])
            } else {
                throw SharedCaptureStoreError.corruptItem
            }
            try protect(destination, fileManager: context.fileManager)
            let copiedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
            guard copiedSize == item.byteCount else { throw SharedCaptureStoreError.corruptItem }
        }
        _ = try readAndValidateItem(at: directory, context: context)
    }

    /// Copies at most the byte count already reserved under the aggregate quota.
    /// A provider that grows or shrinks its file after preflight fails closed.
    private static func copyExactFile(
        from source: URL,
        to destination: URL,
        expectedBytes: Int,
        context: Context
    ) throws {
        guard expectedBytes > 0,
              context.fileManager.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
              ) else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        let input = try FileHandle(forReadingFrom: source)
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch let outputError {
            do {
                try input.close()
            } catch {
                throw SharedCaptureStoreError.cleanupFailed
            }
            throw outputError
        }
        var inputIsOpen = true
        do {
            var remaining = expectedBytes
            while remaining > 0 {
                let requested = min(copyChunkBytes, remaining)
                guard let chunk = try input.read(upToCount: requested), !chunk.isEmpty else {
                    throw SharedCaptureStoreError.corruptItem
                }
                try output.write(contentsOf: chunk)
                remaining -= chunk.count
            }
            if let extra = try input.read(upToCount: 1), !extra.isEmpty {
                throw SharedCaptureStoreError.corruptItem
            }
            try output.synchronize()
            try input.close()
            inputIsOpen = false
            try output.close()
        } catch let copyError {
            var closeFailed = false
            if inputIsOpen {
                do {
                    try input.close()
                } catch {
                    closeFailed = true
                }
            }
            do {
                try output.close()
            } catch {
                closeFailed = true
            }
            if closeFailed {
                throw SharedCaptureStoreError.cleanupFailed
            }
            throw copyError
        }
    }

    private static func removeReservedStageIfPresent(_ directory: URL, context: Context) throws {
        try withCoordination(context) {
            guard try pathEntryExists(directory) else { return }
            let root = temporaryDirectory(context).standardizedFileURL
            guard isDirectChild(directory, of: root),
                  isTemporaryStageName(directory.lastPathComponent),
                  isSafeDirectory(directory) else {
                throw SharedCaptureStoreError.cleanupFailed
            }
            try context.fileManager.removeItem(at: directory)
        }
    }

    /// POSIX record locks are process-scoped, so a same-process probe could
    /// accidentally replace or release its producer's lock. Check the guarded
    /// registry first; only other processes are tested through the lease file.
    private static func reservationIsLiveLocked(
        _ directory: URL,
        context: Context
    ) throws -> Bool {
        let path = directory.standardizedFileURL.path
        if liveReservationRegistry.contains(path) { return true }

        let leaseURL = directory.appendingPathComponent(reservationLeaseFilename)
        guard try pathEntryExists(leaseURL) else { return false }
        let values = try leaseURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        let descriptor = leaseURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDWR | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        defer { Darwin.close(descriptor) }
        while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
            if errno == EINTR { continue }
            if errno == EACCES || errno == EAGAIN { return true }
            throw SharedCaptureStoreError.coordinationFailed
        }
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        return false
    }

    /// Legacy assets already live in the App Group container. Adopt them with
    /// same-volume renames so migration never copies file bytes while holding the
    /// global lock. Any failure after adoption first rolls the asset back.
    private static func publishLegacyItemLocked(
        item: StoredItem,
        sourceFile: URL?,
        context: Context
    ) throws -> URL {
        let staged = try reserveStageLocked(item: item, context: context)
        let destination = readyDirectory(context).appendingPathComponent(
            try readyName(for: item),
            isDirectory: true
        )
        var adoptedAsset: URL?
        do {
            guard try !pathEntryExists(destination) else {
                throw SharedCaptureStoreError.coordinationFailed
            }
            if let sourceFile {
                guard let assetFilename = item.assetFilename else {
                    throw SharedCaptureStoreError.corruptItem
                }
                let asset = staged.appendingPathComponent(assetFilename)
                try atomicRename(sourceFile, asset)
                adoptedAsset = asset
                try protect(asset, fileManager: context.fileManager)
            }
            _ = try readAndValidateItem(at: staged, context: context)
            try atomicRename(staged, destination)
            return destination
        } catch let migrationError {
            do {
                if let adoptedAsset, try pathEntryExists(adoptedAsset) {
                    guard let sourceFile, try !pathEntryExists(sourceFile) else {
                        throw SharedCaptureStoreError.cleanupFailed
                    }
                    try atomicRename(adoptedAsset, sourceFile)
                }
                if try pathEntryExists(staged) {
                    try context.fileManager.removeItem(at: staged)
                }
            } catch let rollbackError {
                do {
                    guard try pathEntryExists(staged),
                          try !pathEntryExists(destination) else {
                        throw SharedCaptureStoreError.cleanupFailed
                    }
                    _ = try readAndValidateItem(at: staged, context: context)
                    try atomicRename(staged, destination)
                    logger.error(
                        "Legacy capture rollback failed, but the complete protected stage was recovered by publication: \(rollbackError.localizedDescription, privacy: .public)"
                    )
                    return destination
                } catch let recoveryError {
                    logger.fault(
                        "Legacy capture adoption, rollback and recovery publication all failed: \(recoveryError.localizedDescription, privacy: .public). The protected stage is retained for explicit recovery."
                    )
                    throw SharedCaptureStoreError.cleanupFailed
                }
            }
            throw migrationError
        }
    }

    private static func publish(
        staged: URL,
        item: StoredItem,
        boundary: ProducerBoundary,
        context: Context,
        now: Date
    ) throws -> String {
        return try withCoordination(context) {
            guard try currentBoundaryStateLocked(context).epoch == boundary.epoch else {
                throw SharedCaptureStoreError.accountBoundaryChanged
            }
            _ = try prepareAndReconcileLocked(
                context: context,
                now: now,
                preservingTemporary: staged
            )
            try assertCapacityLocked(
                for: item,
                excludingTemporary: staged,
                excludingLegacy: nil,
                context: context,
                now: now
            )
            let destination = readyDirectory(context).appendingPathComponent(
                try readyName(for: item),
                isDirectory: true
            )
            guard !context.fileManager.fileExists(atPath: destination.path) else {
                throw SharedCaptureStoreError.coordinationFailed
            }
            try atomicRename(staged, destination)
            let publishedLease = destination.appendingPathComponent(reservationLeaseFilename)
            do {
                try context.fileManager.removeItem(at: publishedLease)
            } catch {
                // The item is already durably published. A retained zero-byte
                // lease marker is harmless and bounded reconciliation removes it.
                logger.error(
                    "Published a capture but could not remove its reservation lease: \(error.localizedDescription, privacy: .public)"
                )
            }
            return item.id
        }
    }

    private static func assertCapacityLocked(
        for item: StoredItem,
        excludingTemporary: URL?,
        excludingLegacy: LegacyQuotaExclusion?,
        context: Context,
        now: Date
    ) throws {
        guard context.limits.maximumItems > 0,
              context.limits.maximumTotalBytes >= 0,
              item.byteCount <= context.limits.maximumTotalBytes else {
            throw SharedCaptureStoreError.inboxFull
        }
        var itemCount = 0
        var byteCount = 0
        var representedItemIDs: Set<String> = []
        try accumulateQuotaLocked(
            in: readyDirectory(context),
            kind: .ready,
            excludingTemporary: excludingTemporary,
            proposedItem: item,
            itemCount: &itemCount,
            byteCount: &byteCount,
            representedItemIDs: &representedItemIDs,
            context: context
        )
        try accumulateQuotaLocked(
            in: claimedDirectory(context),
            kind: .claimed,
            excludingTemporary: excludingTemporary,
            proposedItem: item,
            itemCount: &itemCount,
            byteCount: &byteCount,
            representedItemIDs: &representedItemIDs,
            context: context
        )
        try accumulateQuotaLocked(
            in: temporaryDirectory(context),
            kind: .reservation,
            excludingTemporary: excludingTemporary,
            proposedItem: item,
            itemCount: &itemCount,
            byteCount: &byteCount,
            representedItemIDs: &representedItemIDs,
            context: context
        )
        try accumulateLegacyQuotaLocked(
            excluding: excludingLegacy,
            proposedItem: item,
            itemCount: &itemCount,
            byteCount: &byteCount,
            representedItemIDs: representedItemIDs,
            context: context,
            now: now
        )
    }

    private static func accumulateQuotaLocked(
        in directory: URL,
        kind: QuotaLocationKind,
        excludingTemporary: URL?,
        proposedItem: StoredItem,
        itemCount: inout Int,
        byteCount: inout Int,
        representedItemIDs: inout Set<String>,
        context: Context
    ) throws {
        guard try pathEntryExists(directory) else { return }
        guard isSafeDirectory(directory) else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        var enumerationError: Error?
        guard let enumerator = context.fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        let root = directory.standardizedFileURL
        let excluded = excludingTemporary?.standardizedFileURL
        let examinationLimit = min(
            maximumQuotaEntriesExamined,
            max(
                32,
                max(
                    context.limits.maximumItems,
                    context.limits.maximumReconciliationCandidates
                )
            )
        )
        var examinedEntries = 0
        while let child = enumerator.nextObject() as? URL {
            let (nextExamined, examinationOverflow) = examinedEntries.addingReportingOverflow(1)
            guard !examinationOverflow, nextExamined <= examinationLimit else {
                // Never undercount an unexpectedly large or provider-polluted
                // inbox merely to keep coordination latency bounded.
                throw SharedCaptureStoreError.coordinationFailed
            }
            examinedEntries = nextExamined
            let candidate = child.standardizedFileURL
            guard isDirectChild(candidate, of: root) else { continue }
            let isOwned: Bool
            switch kind {
            case .ready:
                isOwned = isReadyDirectoryName(candidate.lastPathComponent)
            case .claimed:
                isOwned = claimParts(from: candidate.lastPathComponent) != nil
            case .reservation:
                isOwned = isTemporaryStageName(candidate.lastPathComponent)
            }
            guard isOwned else { continue }
            let values = try candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SharedCaptureStoreError.coordinationFailed
            }
            let existing: StoredItem
            if kind == .reservation {
                existing = try readAndValidateReservationMetadata(
                    at: candidate,
                    context: context
                )
            } else {
                existing = try readAndValidateItem(at: candidate, context: context)
            }
            if kind == .reservation, candidate == excluded { continue }

            representedItemIDs.insert(existing.id)

            try accumulateQuotaItem(
                byteCount: existing.byteCount,
                proposedItem: proposedItem,
                itemCount: &itemCount,
                aggregateBytes: &byteCount,
                context: context
            )
        }
        if enumerationError != nil {
            throw SharedCaptureStoreError.coordinationFailed
        }
    }

    private static func accumulateLegacyQuotaLocked(
        excluding exclusion: LegacyQuotaExclusion?,
        proposedItem: StoredItem,
        itemCount: inout Int,
        byteCount: inout Int,
        representedItemIDs: Set<String>,
        context: Context,
        now: Date
    ) throws {
        guard let data = context.defaults?.data(forKey: queueKey) else { return }
        let payloads = try decodeLegacyPayloads(data)
        let activeOwner = try currentBoundaryStateLocked(context).ownerIdentity

        for (index, payload) in payloads.enumerated() {
            let entry = try legacyStoredEntry(
                payload,
                index: index,
                activeOwner: activeOwner,
                context: context,
                now: now
            )
            if let exclusion, exclusion.index == index {
                guard exclusion.item == entry.item,
                      exclusion.item == proposedItem else {
                    throw SharedCaptureStoreError.coordinationFailed
                }
                continue
            }
            // A legacy row already represented by a valid ready, claimed or
            // reserved item is an idempotence record, not another queued item.
            guard !representedItemIDs.contains(entry.item.id) else { continue }
            try accumulateQuotaItem(
                byteCount: entry.item.byteCount,
                proposedItem: proposedItem,
                itemCount: &itemCount,
                aggregateBytes: &byteCount,
                context: context
            )
        }
    }

    private static func accumulateQuotaItem(
        byteCount existingBytes: Int,
        proposedItem: StoredItem,
        itemCount: inout Int,
        aggregateBytes: inout Int,
        context: Context
    ) throws {
        let (nextCount, countOverflow) = itemCount.addingReportingOverflow(1)
        let (nextBytes, byteOverflow) = aggregateBytes.addingReportingOverflow(existingBytes)
        let (totalBytes, totalOverflow) = nextBytes.addingReportingOverflow(
            proposedItem.byteCount
        )
        guard !countOverflow,
              !byteOverflow,
              !totalOverflow,
              nextCount < context.limits.maximumItems,
              totalBytes <= context.limits.maximumTotalBytes else {
            throw SharedCaptureStoreError.inboxFull
        }
        itemCount = nextCount
        aggregateBytes = nextBytes
    }

    // MARK: - Migration and reconciliation

    private static func prepareAndReconcileLocked(
        context: Context,
        now: Date,
        preservingTemporary: URL? = nil
    ) throws -> SharedCaptureReconciliation {
        try prepareDirectories(context)
        var result = SharedCaptureReconciliation()
        var budget = ReconciliationBudget(
            maximumCandidatesPerDirectory: max(
                1,context.limits.maximumReconciliationCandidates
            ),
            maximumMutations: max(1,context.limits.maximumReconciliationMutations)
        )
        try reconcileDirectory(
            temporaryDirectory(context),
            olderThan: now.addingTimeInterval(-context.limits.temporaryLifetime),
            result: &result,
            context: context,
            budget: &budget,
            preserving: preservingTemporary
        )
        try reconcileReadyLocked(result: &result,context: context,budget: &budget)
        try reconcileClaimedLocked(
            now: now,result: &result,context: context,budget: &budget
        )
        if budget.hasMutationCapacity {
            result.migratedLegacyItems = try migrateLegacyLocked(
                context: context,
                now: now,
                maximumCandidates: budget.maximumCandidatesPerDirectory,
                maximumMutations: budget.maximumMutations - budget.mutations
            )
            budget.recordMutations(result.migratedLegacyItems)
        }
        try reconcileLegacyOrphansLocked(
            now: now,result: &result,context: context,budget: &budget
        )
        return result
    }

    private static func reconcileReadyLocked(
        result: inout SharedCaptureReconciliation,
        context: Context,
        budget: inout ReconciliationBudget
    ) throws {
        let root = readyDirectory(context).standardizedFileURL
        let candidates = try boundedContents(
            of: root,
            limit: budget.maximumCandidatesPerDirectory,
            context: context,
            where: {
                isDirectChild($0, of: root)
                    && isSafeDirectory($0)
                    && isReadyDirectoryName($0.lastPathComponent)
            },
            sortedBy: {
                readyReconciliationPriority($0) == readyReconciliationPriority($1)
                    ? $0.lastPathComponent < $1.lastPathComponent
                    : readyReconciliationPriority($0) < readyReconciliationPriority($1)
            }
        )
        for url in candidates {
            guard budget.hasMutationCapacity else { break }
            guard isDirectChild(url,of: root),isSafeDirectory(url) else { continue }
            // A directory merely living beside the inbox is not deletion
            // authority. Only names HausKlar can have generated are candidates.
            guard isReadyDirectoryName(url.lastPathComponent) else { continue }
            let item: StoredItem
            do {
                item = try readAndValidateItem(at: url, context: context)
            } catch SharedCaptureStoreError.corruptItem {
                do {
                    try context.fileManager.removeItem(at: url)
                    result.removedInvalidItems += 1
                    budget.recordMutation()
                } catch {
                    continue
                }
                continue
            } catch {
                // An I/O failure is not proof of corruption and grants no
                // deletion authority; a later bounded pass retries it.
                continue
            }
            result.removedOrphanAssets += try removeOrphanAssets(
                in: url,item: item,context: context,budget: &budget
            )
        }
    }

    private static func reconcileClaimedLocked(
        now: Date,
        result: inout SharedCaptureReconciliation,
        context: Context,
        budget: inout ReconciliationBudget
    ) throws {
        let root = claimedDirectory(context).standardizedFileURL
        let candidates = try boundedContents(
            of: root,
            limit: budget.maximumCandidatesPerDirectory,
            context: context,
            where: {
                isDirectChild($0, of: root)
                    && isSafeDirectory($0)
                    && claimParts(from: $0.lastPathComponent) != nil
            },
            sortedBy: {
                claimedReconciliationPriority($0,now: now)
                    == claimedReconciliationPriority($1,now: now)
                    ? $0.lastPathComponent < $1.lastPathComponent
                    : claimedReconciliationPriority($0,now: now)
                        < claimedReconciliationPriority($1,now: now)
            }
        )
        for url in candidates {
            guard budget.hasMutationCapacity else { break }
            guard isDirectChild(url,of: root),isSafeDirectory(url) else { continue }
            guard let parts = claimParts(from: url.lastPathComponent) else { continue }
            let item: StoredItem
            do {
                item = try readAndValidateItem(at: url, context: context)
            } catch SharedCaptureStoreError.corruptItem {
                do {
                    try context.fileManager.removeItem(at: url)
                    result.removedInvalidItems += 1
                    budget.recordMutation()
                } catch {
                    continue
                }
                continue
            } catch {
                // A transient read failure retains the claimed item.
                continue
            }
            result.removedOrphanAssets += try removeOrphanAssets(
                in: url,item: item,context: context,budget: &budget
            )
            guard budget.hasMutationCapacity,parts.expiresAt <= now else { continue }
            let releasedName: String
            if let originalName = readyName(fromClaimedName: url.lastPathComponent) {
                releasedName = originalName
            } else {
                releasedName = try readyName(for: item)
            }
            let destination = readyDirectory(context).appendingPathComponent(
                releasedName,
                isDirectory: true
            )
            do {
                if try pathEntryExists(destination) {
                    guard isSafeDirectory(destination) else { continue }
                    let existing: StoredItem
                    do {
                        existing = try readAndValidateItem(at: destination, context: context)
                    } catch {
                        continue
                    }
                    guard existing.id == item.id else { continue }
                    try context.fileManager.removeItem(at: url)
                    result.removedInvalidItems += 1
                } else {
                    try atomicRename(url,destination)
                    result.releasedExpiredClaims += 1
                }
                budget.recordMutation()
            } catch {
                // A validated claimed item is live data; retry later.
                continue
            }
        }
    }

    private static func reconcileDirectory(
        _ directory: URL,
        olderThan cutoff: Date,
        result: inout SharedCaptureReconciliation,
        context: Context,
        budget: inout ReconciliationBudget,
        preserving preservedDirectory: URL?
    ) throws {
        let root = directory.standardizedFileURL
        let candidates = try boundedContents(
            of: root,
            limit: budget.maximumCandidatesPerDirectory,
            context: context,
            where: {
                isDirectChild($0, of: root)
                    && isSafeDirectory($0)
                    && isTemporaryStageName($0.lastPathComponent)
            },
            sortedBy: {
                reconciliationDate($0) == reconciliationDate($1)
                    ? $0.lastPathComponent < $1.lastPathComponent
                    : reconciliationDate($0) < reconciliationDate($1)
            }
        )
        let preserved = preservedDirectory?.standardizedFileURL
        for url in candidates {
            guard budget.hasMutationCapacity else { break }
            guard url.standardizedFileURL != preserved else { continue }
            guard try !reservationIsLiveLocked(url, context: context) else { continue }
            do {
                _ = try readAndValidateReservationMetadata(at: url, context: context)
            } catch SharedCaptureStoreError.corruptItem {
                do {
                    try context.fileManager.removeItem(at: url)
                    result.removedTemporaryItems += 1
                    budget.recordMutation()
                } catch {
                    continue
                }
                continue
            } catch {
                // Ambiguous I/O is not deletion authority. Retain it; quota
                // accounting subsequently fails closed until a clean read.
                continue
            }
            let date = reconciliationDate(url)
            guard isDirectChild(url,of: root),isSafeDirectory(url),
                  isTemporaryStageName(url.lastPathComponent),
                  date != .distantFuture,date <= cutoff else { continue }
            do {
                try context.fileManager.removeItem(at: url)
                result.removedTemporaryItems += 1
                budget.recordMutation()
            } catch {
                continue
            }
        }
    }

    private static func migrateLegacyLocked(
        context: Context,
        now: Date,
        maximumCandidates: Int,
        maximumMutations: Int
    ) throws -> Int {
        let marker = inboxRoot(context).appendingPathComponent(migrationMarkerFilename)
        if context.fileManager.fileExists(atPath: marker.path) { return 0 }
        guard let data = context.defaults?.data(forKey: queueKey) else {
            try Data().write(to: marker, options: [.atomic, .completeFileProtection])
            context.defaults?.removeObject(forKey: queueKey)
            return 0
        }
        let legacy: [SharedCapturePayload]
        do {
            legacy = try decodeLegacyPayloads(data)
        } catch {
            logger.error(
                "Legacy capture metadata is malformed and was retained: \(error.localizedDescription, privacy: .public). Reconciliation: migration retries only after the metadata is repaired or explicitly purged."
            )
            return 0
        }

        var migrated = 0
        var remaining: [SharedCapturePayload] = []
        var existing = try allValidItems(context: context)
        let activeOwner = try currentBoundaryStateLocked(context).ownerIdentity

        for (index, payload) in legacy.enumerated() {
            guard index < maximumCandidates,migrated < maximumMutations else {
                remaining.append(payload)
                continue
            }
            do {
                let entry = try legacyStoredEntry(
                    payload,
                    index: index,
                    activeOwner: activeOwner,
                    context: context,
                    now: now
                )
                let item = entry.item
                if let published = existing.first(where: { $0.item.id == item.id }) {
                    // A matching ID is not enough: older releases could map
                    // distinct legacy IDs to the same truncated filename. Text
                    // can be compared exactly; a still-present file is retained
                    // because proving byte equality would require bulk I/O here.
                    guard entry.sourceFile == nil, published.item == item else {
                        remaining.append(payload)
                        continue
                    }
                    migrated += 1
                    continue
                }

                do {
                    try assertCapacityLocked(
                        for: item,
                        excludingTemporary: nil,
                        excludingLegacy: LegacyQuotaExclusion(index: index, item: item),
                        context: context,
                        now: now
                    )
                } catch SharedCaptureStoreError.inboxFull {
                    remaining.append(payload)
                    continue
                }
                let destination = try publishLegacyItemLocked(
                    item: item,
                    sourceFile: entry.sourceFile,
                    context: context
                )
                existing.append(ItemLocation(directory: destination, item: item, state: .ready))
                migrated += 1
            } catch {
                // Invalid legacy rows are not deliverable. Keep a bounded recovery
                // record in UserDefaults until an authorised purge rather than
                // silently turning malformed metadata into an arbitrary file read.
                remaining.append(payload)
            }
        }

        if remaining.isEmpty {
            context.defaults?.removeObject(forKey: queueKey)
            try Data().write(to: marker, options: [.atomic, .completeFileProtection])
        } else {
            let encoded = try JSONEncoder().encode(remaining)
            context.defaults?.set(encoded, forKey: queueKey)
        }
        return migrated
    }

    private static func decodeLegacyPayloads(_ data: Data) throws -> [SharedCapturePayload] {
        guard !data.isEmpty, data.count <= maximumLegacyQueueBytes else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        let payloads: [SharedCapturePayload]
        do {
            payloads = try JSONDecoder().decode([SharedCapturePayload].self, from: data)
        } catch {
            throw SharedCaptureStoreError.coordinationFailed
        }
        guard payloads.count <= maximumQuotaEntriesExamined else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        return payloads
    }

    private static func legacyStoredEntry(
        _ payload: SharedCapturePayload,
        index: Int,
        activeOwner: String?,
        context: Context,
        now: Date
    ) throws -> LegacyStoredEntry {
        guard payload.id.count <= maximumIdentityCharacters else {
            throw SharedCaptureStoreError.corruptItem
        }
        let owner = payload.ownerIdentity ?? activeOwner
        guard owner.map({ isValidIdentity($0) }) ?? true else {
            throw SharedCaptureStoreError.corruptItem
        }
        let createdAt = payload.createdAt == .distantPast
            ? now.addingTimeInterval(TimeInterval(index) / 1_000)
            : payload.createdAt
        guard createdAt.timeIntervalSince1970.isFinite else {
            throw SharedCaptureStoreError.corruptItem
        }
        let stableID = try stableLegacyID(
            payload,
            index: index,
            resolvedOwner: owner
        )
        if let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            guard payload.filePath == nil,
                  text.count <= context.limits.maximumTextCharacters else {
                throw SharedCaptureStoreError.corruptItem
            }
            return LegacyStoredEntry(
                item: StoredItem(
                    version: 2,
                    id: stableID,
                    kind: .text,
                    text: text,
                    assetFilename: nil,
                    originalFilename: nil,
                    mediaType: "text/plain",
                    byteCount: text.lengthOfBytes(using: .utf8),
                    createdAt: createdAt,
                    ownerIdentity: owner
                ),
                sourceFile: nil
            )
        }

        guard let path = payload.filePath else {
            throw SharedCaptureStoreError.corruptItem
        }
        let legacyRoot = context.containerURL
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
            .standardizedFileURL
        // Resolve no paths before this check: a symlinked legacy root must never
        // turn a path outside the App Group into migration authority.
        guard isSafeDirectory(legacyRoot) else {
            throw SharedCaptureStoreError.corruptItem
        }
        let legacyFile = URL(fileURLWithPath: path).standardizedFileURL
        guard isDirectChild(legacyFile, of: legacyRoot),
              isSafeRegularFile(legacyFile) else {
            throw SharedCaptureStoreError.corruptItem
        }
        let values = try legacyFile.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= context.limits.maximumFileBytes else {
            throw SharedCaptureStoreError.corruptItem
        }
        let filename = try validatedFilename(
            payload.originalFilename ?? legacyFile.lastPathComponent,
            limits: context.limits
        )
        let type = try validatedMediaType(
            payload.mediaType,
            filename: filename,
            limits: context.limits
        )
        return LegacyStoredEntry(
            item: makeFileItem(
                filename: filename,
                mediaType: type,
                byteCount: size,
                ownerIdentity: owner,
                now: createdAt,
                id: stableID
            ),
            sourceFile: legacyFile
        )
    }

    private static func reconcileLegacyOrphansLocked(
        now: Date,
        result: inout SharedCaptureReconciliation,
        context: Context,
        budget: inout ReconciliationBudget
    ) throws {
        let directory = context.containerURL
            .appendingPathComponent(legacyDirectoryName,isDirectory: true)
            .standardizedFileURL
        guard context.fileManager.fileExists(atPath: directory.path),
              isSafeDirectory(directory) else { return }
        let retainedPaths: Set<String>
        if let data = context.defaults?.data(forKey: queueKey) {
            do {
                let entries = try decodeLegacyPayloads(data)
                retainedPaths = Set(entries.compactMap(\ .filePath).map {
                    URL(fileURLWithPath: $0).standardizedFileURL.path
                })
            } catch {
                logger.error(
                    "Legacy capture metadata could not be decoded during orphan cleanup: \(error.localizedDescription, privacy: .public). Reconciliation: cleanup fails closed and retries without deleting any legacy file."
                )
                return
            }
        } else {
            retainedPaths = []
        }
        let candidates = try boundedContents(
            of: directory,
            limit: budget.maximumCandidatesPerDirectory,
            context: context,
            where: {
                $0.standardizedFileURL.deletingLastPathComponent() == directory
                    && isSafeRegularFile($0)
            },
            sortedBy: {
                reconciliationDate($0) == reconciliationDate($1)
                    ? $0.lastPathComponent < $1.lastPathComponent
                    : reconciliationDate($0) < reconciliationDate($1)
            }
        )
        for url in candidates {
            guard budget.hasMutationCapacity else { break }
            let standard = url.standardizedFileURL
            let date = reconciliationDate(standard)
            guard standard.deletingLastPathComponent() == directory,
                  !retainedPaths.contains(standard.path),
                  isSafeRegularFile(standard),
                  date != .distantFuture,
                  date <= now.addingTimeInterval(-context.limits.temporaryLifetime) else {
                continue
            }
            do {
                try context.fileManager.removeItem(at: standard)
                result.removedOrphanAssets += 1
                budget.recordMutation()
            } catch {
                continue
            }
        }
        if budget.hasMutationCapacity,
           directoryIsEmpty(directory, fileManager: context.fileManager) {
            do {
                try context.fileManager.removeItem(at: directory)
                budget.recordMutation()
            } catch {
                return
            }
        }
    }

    // MARK: - Validation and filesystem helpers

    private static func isValidIdentity(_ identity: String) -> Bool {
        guard !identity.isEmpty,
              identity.count <= maximumIdentityCharacters,
              identity == identity.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return identity.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func resolvedContext(_ context: Context?) throws -> Context {
        let resolved: Context
        if let context {
            resolved = context
        } else {
            guard let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            ) else { throw SharedCaptureStoreError.containerUnavailable }
            resolved = Context(
                containerURL: container,
                defaults: UserDefaults(suiteName: suiteName)
            )
        }
        guard resolved.limits.claimLifetime.isFinite,
              resolved.limits.claimLifetime > 0,
              resolved.limits.temporaryLifetime.isFinite,
              resolved.limits.temporaryLifetime > 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        return resolved
    }

    /// Returns the durable account-boundary state while coordination is held,
    /// creating the pre-boundary deployment's initial value exactly once.
    private static func currentBoundaryStateLocked(_ context: Context) throws -> BoundaryState {
        let url = context.containerURL.appendingPathComponent(boundaryStateFilename)
        guard try pathEntryExists(url) else {
            let mirroredOwner = context.defaults?.string(forKey: activeIdentityKey)
            guard mirroredOwner.map({ isValidIdentity($0) }) ?? true else {
                // Never turn an untrusted or damaged compatibility mirror into
                // durable account authority on first launch after upgrade.
                throw SharedCaptureStoreError.coordinationFailed
            }
            return try rotateBoundaryStateLocked(
                ownerIdentity: mirroredOwner,
                context: context
            )
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumBoundaryStateBytes else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let state: BoundaryState
        do {
            state = try JSONDecoder().decode(BoundaryState.self, from: data)
        } catch {
            throw SharedCaptureStoreError.coordinationFailed
        }
        guard data.count == byteCount,
              state.version == 1,
              state.ownerIdentity.map({ isValidIdentity($0) }) ?? true else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        return state
    }

    /// Replaces owner and epoch in one atomic record, then synchronizes both the
    /// file and its parent before an account-boundary operation may complete.
    @discardableResult
    private static func rotateBoundaryStateLocked(
        ownerIdentity: String?,
        context: Context
    ) throws -> BoundaryState {
        guard ownerIdentity.map({ isValidIdentity($0) }) ?? true else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        let state = BoundaryState(version: 1, epoch: UUID(), ownerIdentity: ownerIdentity)
        let data = try JSONEncoder().encode(state)
        guard !data.isEmpty, data.count <= maximumBoundaryStateBytes else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        let url = context.containerURL.appendingPathComponent(boundaryStateFilename)
        try data.write(
            to: url,
            options: [.atomic, .completeFileProtection]
        )
        try protect(url, fileManager: context.fileManager)
        try synchronizeFile(url)
        try synchronizeDirectory(context.containerURL)
        return state
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
    }

    /// Unlike `FileManager.fileExists`, `lstat` treats a broken symlink as an
    /// existing path entry. Claim release must never rename across one.
    private static func pathEntryExists(_ url: URL) throws -> Bool {
        var information = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &information)
        }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func withCoordination<T>(
        _ context: Context,
        _ operation: () throws -> T
    ) throws -> T {
        processCoordinationLock.lock()
        defer { processCoordinationLock.unlock() }

        try context.fileManager.createDirectory(
            at: context.containerURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let lockURL = context.containerURL.appendingPathComponent(lockFilename)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SharedCaptureStoreError.coordinationFailed }
        defer { Darwin.close(descriptor) }
        try protect(lockURL, fileManager: context.fileManager)

        while Darwin.lockf(descriptor, F_LOCK, 0) != 0 {
            guard errno == EINTR else { throw SharedCaptureStoreError.coordinationFailed }
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try operation()
    }

    private static func prepareDirectories(_ context: Context) throws {
        try createProtectedDirectory(inboxRoot(context), fileManager: context.fileManager)
        try createProtectedDirectory(readyDirectory(context), fileManager: context.fileManager)
        try createProtectedDirectory(claimedDirectory(context), fileManager: context.fileManager)
        try createProtectedDirectory(temporaryDirectory(context), fileManager: context.fileManager)
    }

    private static func createProtectedDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,values.isSymbolicLink != true else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        try protect(url, fileManager: fileManager)
    }

    private static func protect(_ url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private static func atomicRename(_ source: URL, _ destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
    }

    private static func writeMetadata(
        _ item: StoredItem,
        to directory: URL,
        context: Context
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampCodec.string(from: date))
        }
        let data = try encoder.encode(item)
        let url = directory.appendingPathComponent(metadataFilename)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try protect(url, fileManager: context.fileManager)
    }

    private static func readAndValidateReservationMetadata(
        at directory: URL,
        context: Context
    ) throws -> StoredItem {
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw SharedCaptureStoreError.corruptItem
        }
        let metadata = directory.appendingPathComponent(metadataFilename)
        guard try pathEntryExists(metadata) else {
            throw SharedCaptureStoreError.corruptItem
        }
        let metadataValues = try metadata.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard metadataValues.isRegularFile == true,
              metadataValues.isSymbolicLink != true,
              let metadataBytes = metadataValues.fileSize,
              metadataBytes > 0,
              metadataBytes <= maximumMetadataBytes else {
            throw SharedCaptureStoreError.corruptItem
        }
        let data = try Data(contentsOf: metadata, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = timestampCodec.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid shared-capture timestamp"
                )
            }
            return date
        }
        let item: StoredItem
        do {
            item = try decoder.decode(StoredItem.self, from: data)
        } catch {
            throw SharedCaptureStoreError.corruptItem
        }
        let name = directory.lastPathComponent
        let directoryMatchesItem = itemIdentifier(fromReadyDirectoryName: name) == item.id
            || readyName(fromClaimedName: name)
                .flatMap { itemIdentifier(fromReadyDirectoryName: $0) } == item.id
            || (isTemporaryStageName(name) && name.hasPrefix("stage-\(item.id)-"))
        guard item.version == 2,
              isOwnedItemIdentifier(item.id),
              directoryMatchesItem,
              item.ownerIdentity.map({ isValidIdentity($0) }) ?? true,
              item.byteCount >= 0,
              item.byteCount <= context.limits.maximumFileBytes else {
            throw SharedCaptureStoreError.corruptItem
        }
        switch item.kind {
        case .text:
            guard let text = item.text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= context.limits.maximumTextCharacters,
                  item.byteCount == text.lengthOfBytes(using: .utf8),
                  item.assetFilename == nil else {
                throw SharedCaptureStoreError.corruptItem
            }
        case .file:
            guard item.text == nil,
                  let assetFilename = item.assetFilename,
                  !assetFilename.contains("/"), !assetFilename.contains("\\"),
                  let originalFilename = item.originalFilename,
                  let mediaType = item.mediaType else {
                throw SharedCaptureStoreError.corruptItem
            }
            do {
                _ = try validatedFilename(originalFilename, limits: context.limits)
                _ = try validatedMediaType(
                    mediaType,
                    filename: originalFilename,
                    limits: context.limits
                )
            } catch {
                throw SharedCaptureStoreError.corruptItem
            }
            guard item.byteCount > 0 else { throw SharedCaptureStoreError.corruptItem }
        }
        return item
    }

    private static func readAndValidateItem(at directory: URL, context: Context) throws -> StoredItem {
        let item = try readAndValidateReservationMetadata(at: directory, context: context)
        guard item.kind == .file else { return item }
        guard let assetFilename = item.assetFilename else {
            throw SharedCaptureStoreError.corruptItem
        }
        let asset = directory.appendingPathComponent(assetFilename)
        guard try pathEntryExists(asset) else {
            // Confirmed absence is corruption, not an ambiguous provider I/O
            // failure. Reconciliation may therefore remove the unusable item.
            throw SharedCaptureStoreError.corruptItem
        }
        let values = try asset.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == item.byteCount else {
            throw SharedCaptureStoreError.corruptItem
        }
        return item
    }

    private static func payload(
        for item: StoredItem,
        in directory: URL,
        context: Context
    ) throws -> SharedCapturePayload {
        _ = try readAndValidateItem(at: directory, context: context)
        return SharedCapturePayload(
            id: item.id,
            text: item.text,
            filePath: item.assetFilename.map { directory.appendingPathComponent($0).path },
            ownerIdentity: item.ownerIdentity,
            createdAt: item.createdAt,
            originalFilename: item.originalFilename,
            mediaType: item.mediaType,
            byteCount: item.byteCount
        )
    }

    private static func validItems(
        in directory: URL,
        state: SharedCaptureRecoveryItem.State,
        context: Context
    ) throws -> [ItemLocation] {
        let parent = directory.standardizedFileURL
        let candidates = try boundedContents(
            of: directory,
            limit: max(1, context.limits.maximumReconciliationCandidates),
            context: context,
            where: {
                isDirectChild($0, of: parent)
                    && isSafeDirectory($0)
                    && (state == .ready
                        ? isReadyDirectoryName($0.lastPathComponent)
                        : claimParts(from: $0.lastPathComponent) != nil)
            },
            sortedBy: { $0.lastPathComponent < $1.lastPathComponent }
        )
        var items: [ItemLocation] = []
        items.reserveCapacity(candidates.count)
        for url in candidates where isSafeDirectory(url) {
            do {
                let item = try readAndValidateItem(at: url, context: context)
                items.append(ItemLocation(directory: url, item: item, state: state))
            } catch SharedCaptureStoreError.corruptItem {
                // Corrupt entries are excluded from delivery and removed only by
                // the mutation-budgeted reconciliation pass.
                continue
            }
        }
        return items
    }

    private static func allValidItems(context: Context) throws -> [ItemLocation] {
        try validItems(in: readyDirectory(context), state: .ready, context: context)
            + validItems(in: claimedDirectory(context), state: .claimed, context: context)
    }

    /// Streams every direct child while retaining only the best bounded set of
    /// exact-owned candidates. Unrelated App Group entries therefore consume
    /// neither reconciliation memory nor the candidate budget.
    private static func boundedContents(
        of directory: URL,
        limit: Int,
        context: Context,
        where isCandidate: (URL) -> Bool,
        sortedBy areInIncreasingOrder: (URL, URL) -> Bool
    ) throws -> [URL] {
        guard limit > 0 else { return [] }
        guard context.fileManager.fileExists(atPath: directory.path) else { return [] }
        guard isSafeDirectory(directory) else { throw SharedCaptureStoreError.corruptItem }
        var enumerationError: Error?
        guard let enumerator = context.fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .creationDateKey,
                .contentModificationDateKey,
            ],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw SharedCaptureStoreError.corruptItem }
        var selected: [URL] = []
        while let child = enumerator.nextObject() as? URL {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory.standardizedFileURL,
                  isCandidate(candidate) else { continue }
            selected.append(candidate)
            selected.sort(by: areInIncreasingOrder)
            if selected.count > limit { selected.removeLast() }
        }
        if enumerationError != nil { throw SharedCaptureStoreError.corruptItem }
        return selected
    }

    private static func removeOrphanAssets(
        in directory: URL,
        item: StoredItem,
        context: Context,
        budget: inout ReconciliationBudget
    ) throws -> Int {
        let allowed = Set([metadataFilename, item.assetFilename].compactMap { $0 })
        var removed = 0
        let candidates = try boundedContents(
            of: directory,
            limit: budget.maximumCandidatesPerDirectory,
            context: context,
            where: {
                !allowed.contains($0.lastPathComponent)
                    && isDirectChild($0, of: directory)
                    && isSafeRegularFile($0)
            },
            sortedBy: { $0.lastPathComponent < $1.lastPathComponent }
        )
        for url in candidates {
            guard budget.hasMutationCapacity else { break }
            guard isDirectChild(url,of: directory),isSafeRegularFile(url) else { continue }
            do {
                try context.fileManager.removeItem(at: url)
                removed += 1
                budget.recordMutation()
            } catch {
                continue
            }
        }
        return removed
    }

    private static func validatedFilename(_ raw: String, limits: Limits) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= limits.maximumFilenameCharacters,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw SharedCaptureStoreError.invalidFilename
        }
        let fileExtension = (value as NSString).pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw SharedCaptureStoreError.unsupportedFile
        }
        return value
    }

    private static func validatedMediaType(
        _ raw: String?,
        filename: String,
        limits: Limits
    ) throws -> String {
        let inferred = inferredMediaType(forExtension: (filename as NSString).pathExtension.lowercased())
        let value = (raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).flatMap {
            $0.isEmpty ? nil : $0
        } ?? inferred
        guard value.count <= limits.maximumMediaTypeCharacters,
              value.range(of: #"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"#,
                          options: .regularExpression) != nil else {
            throw SharedCaptureStoreError.invalidMediaType
        }
        let supported = value == "application/pdf" || value == "text/plain" || value.hasPrefix("image/")
        guard supported else { throw SharedCaptureStoreError.unsupportedFile }
        return value
    }

    private static func inferredMediaType(forExtension value: String) -> String {
        switch value {
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        default: "image/jpeg"
        }
    }

    private static func preferredExtension(filename: String, mediaType: String) -> String {
        let existing = (filename as NSString).pathExtension.lowercased()
        if supportedExtensions.contains(existing) { return existing }
        switch mediaType {
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        default: return "jpg"
        }
    }

    private struct LegacyIdentifierSeed: Encodable {
        let payload: SharedCapturePayload
        let resolvedOwner: String?
        let index: Int
    }

    private static func stableLegacyID(
        _ payload: SharedCapturePayload,
        index: Int,
        resolvedOwner: String?
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let seed = try encoder.encode(LegacyIdentifierSeed(
            payload: payload,
            resolvedOwner: resolvedOwner,
            index: index
        ))
        let digest = SHA256.hash(data: seed)
            .map { String(format: "%02x", $0) }
            .joined()
        return "legacy-\(digest)"
    }

    private static func readyName(for item: StoredItem) throws -> String {
        let milliseconds = max(try encodedMilliseconds(item.createdAt), 0)
        return String(format: "%016lld-%@%@", milliseconds, item.id, itemSuffix)
    }

    private static func claimName(
        readyName: String,
        expiresAt: Date,
        leaseID: String
    ) throws -> (name: String, expiresAt: Date) {
        let expiry = try encodedMilliseconds(expiresAt)
        return (
            "\(readyName)\(claimMarker)\(expiry).\(leaseID)",
            Date(timeIntervalSince1970: TimeInterval(expiry) / 1_000)
        )
    }

    private static func encodedMilliseconds(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        return Int64(milliseconds.rounded())
    }

    private static func validateOperationDate(_ date: Date, context: Context) throws {
        try validateTimestampDate(date)
        try validateTimestampDate(
            date.addingTimeInterval(-context.limits.temporaryLifetime)
        )
    }

    private static func validateTimestampDate(_ date: Date) throws {
        let seconds = date.timeIntervalSince1970
        // ISO8601DateFormatter persists four-digit Gregorian years. Keep every
        // operation and derived reconciliation cutoff inside that exact codec
        // domain before any directory can be reserved, claimed, or reaped.
        guard seconds >= -62_135_596_800,
              seconds <= 253_402_300_799.999 else {
            throw SharedCaptureStoreError.coordinationFailed
        }
        _ = try encodedMilliseconds(date)
    }

    private static func claimParts(from name: String) -> (expiresAt: Date, leaseID: String)? {
        guard let range = name.range(of: claimMarker, options: .backwards) else { return nil }
        let ready = String(name[..<range.lowerBound])
        let suffix = name[range.upperBound...].split(separator: ".", maxSplits: 1).map(String.init)
        guard isReadyDirectoryName(ready),
              suffix.count == 2,
              let milliseconds = Int64(suffix[0]),
              UUID(uuidString: suffix[1]) != nil else { return nil }
        return (Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000), suffix[1])
    }

    private static func readyName(fromClaimedName name: String) -> String? {
        guard let range = name.range(of: claimMarker, options: .backwards) else { return nil }
        return String(name[..<range.lowerBound])
    }

    private static func verifiedClaimDirectory(
        _ claim: SharedCaptureClaim,
        context: Context
    ) throws -> URL {
        let root = claimedDirectory(context).standardizedFileURL
        let directory = URL(fileURLWithPath: claim.claimedDirectoryPath).standardizedFileURL
        guard directory.deletingLastPathComponent() == root,
              let parts = claimParts(from: directory.lastPathComponent),
              parts.leaseID == claim.leaseID else {
            throw SharedCaptureStoreError.staleClaim
        }
        return directory
    }

    private static func oldestFirst(_ lhs: ItemLocation, _ rhs: ItemLocation) -> Bool {
        if lhs.item.createdAt != rhs.item.createdAt { return lhs.item.createdAt < rhs.item.createdAt }
        return lhs.item.id < rhs.item.id
    }

    private static func isDirectChild(_ child: URL, of parent: URL) -> Bool {
        child.standardizedFileURL.deletingLastPathComponent() == parent.standardizedFileURL
    }

    private static func isSafeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func directoryIsEmpty(_ directory: URL, fileManager: FileManager) -> Bool {
        var didEncounterError = false
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                didEncounterError = true
                return false
            }
        ) else { return false }
        let first = enumerator.nextObject()
        return first == nil && !didEncounterError
    }

    private static func reconciliationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .creationDateKey,
        ])
        return values?.contentModificationDate ?? values?.creationDate ?? .distantFuture
    }

    private static func readyReconciliationPriority(_ url: URL) -> Int {
        guard isSafeDirectory(url) else { return 3 }
        return isReadyDirectoryName(url.lastPathComponent) ? 1 : 3
    }

    private static func claimedReconciliationPriority(_ url: URL, now: Date) -> Int {
        guard isSafeDirectory(url) else { return 3 }
        guard let parts = claimParts(from: url.lastPathComponent) else { return 3 }
        return parts.expiresAt <= now ? 0 : 1
    }

    private static func isTemporaryStageName(_ name: String) -> Bool {
        let prefix = "stage-"
        guard name.hasPrefix(prefix),name.count > prefix.count + 37 else { return false }
        let uuid = String(name.suffix(36))
        let separator = name.index(name.endIndex,offsetBy: -37)
        let identifier = String(name[name.index(name.startIndex, offsetBy: prefix.count)..<separator])
        return name[separator] == "-"
            && isOwnedItemIdentifier(identifier)
            && UUID(uuidString: uuid) != nil
    }

    private static func isReadyDirectoryName(_ name: String) -> Bool {
        itemIdentifier(fromReadyDirectoryName: name) != nil
    }

    private static func itemIdentifier(fromReadyDirectoryName name: String) -> String? {
        guard name.hasSuffix(itemSuffix) else { return nil }
        let base = String(name.dropLast(itemSuffix.count))
        guard base.count > 17 else { return nil }
        let timestampEnd = base.index(base.startIndex, offsetBy: 16)
        let timestamp = base[..<timestampEnd]
        guard timestamp.allSatisfy({ $0.isASCII && $0.isNumber }),
              base[timestampEnd] == "-" else { return nil }
        let identifierStart = base.index(after: timestampEnd)
        let identifier = String(base[identifierStart...])
        return isOwnedItemIdentifier(identifier) ? identifier : nil
    }

    private static func isOwnedItemIdentifier(_ value: String) -> Bool {
        if UUID(uuidString: value) != nil { return true }
        guard value.hasPrefix("legacy-"), value.count <= 87 else { return false }
        let suffix = value.dropFirst("legacy-".count)
        return !suffix.isEmpty && suffix.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-"
        }
    }

    private static func inboxRoot(_ context: Context) -> URL {
        context.containerURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func readyDirectory(_ context: Context) -> URL {
        inboxRoot(context).appendingPathComponent(readyDirectoryName, isDirectory: true)
    }

    private static func claimedDirectory(_ context: Context) -> URL {
        inboxRoot(context).appendingPathComponent(claimedDirectoryName, isDirectory: true)
    }

    private static func temporaryDirectory(_ context: Context) -> URL {
        inboxRoot(context).appendingPathComponent(temporaryDirectoryName, isDirectory: true)
    }
}
