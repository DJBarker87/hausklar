import CryptoKit
import Darwin
import Foundation
import os

private let fitnessPendingFITInboxLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessPendingFITInbox"
)

private final class FitnessPendingFITLiveReservations: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    func insert(_ url: URL) {
        lock.lock()
        paths.insert(url.standardizedFileURL.path)
        lock.unlock()
    }

    func remove(_ url: URL) {
        lock.lock()
        paths.remove(url.standardizedFileURL.path)
        lock.unlock()
    }

    func contains(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(url.standardizedFileURL.path)
    }
}

private final class FitnessPendingFITReservationLease: @unchecked Sendable {
    let directory: URL
    private let descriptor: Int32
    private let lockURL: URL
    private let stateLock = NSLock()
    private var isClosed = false

    init(directory: URL, lockURL: URL, descriptor: Int32) {
        self.directory = directory
        self.lockURL = lockURL
        self.descriptor = descriptor
    }

    func finishBeforePublishing() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return }
        guard unlink(lockURL.path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        isClosed = true
    }

    func cancel() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        isClosed = true
    }

    deinit { cancel() }
}

struct SharedFitnessFITPayload: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let filePath: String
    let originalFilename: String
    let byteCount: Int
    let createdAt: String
    let ownerIdentity: String?
}

struct FitnessPendingFITClaim: Identifiable, Equatable, Sendable {
    var id: String { leaseID }
    let leaseID: String
    let expiresAt: Date
    let payload: SharedFitnessFITPayload
    fileprivate let claimedDirectoryPath: String
    fileprivate var verifiedAssetFingerprint: FitnessPendingFITAssetFingerprint?
}

private struct FitnessPendingFITAssetFingerprint: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

enum FitnessPendingFITInboxError: LocalizedError {
    case inactiveIdentity
    case itemNotFound
    case invalidFile
    case containerUnavailable
    case coordinationFailed
    case inboxFull
    case staleClaim
    case claimRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .inactiveIdentity: "HausKlar locked before that FIT file could be adopted."
        case .itemNotFound: "That shared FIT file is no longer waiting for review."
        case .invalidFile: "That shared item is not a valid FIT file."
        case .containerUnavailable: "HausKlar could not open its protected FIT inbox."
        case .coordinationFailed: "The FIT inbox is busy. Please try again."
        case .inboxFull: "The FIT inbox is full. Open HausKlar and review waiting imports first."
        case .staleClaim: "That FIT handoff expired and was recovered for a later attempt."
        case .claimRecoveryFailed:
            "The FIT import was kept safely, but its handoff could not be reset. Try again later."
        }
    }
}

/// A cross-process, crash-safe handoff between the share extension and app.
///
/// A producer builds a complete protected item in `temporary` and publishes it
/// with one directory rename. The app claims with another rename, then deletes
/// only that exact lease after FitnessActivityRepository has durably copied the
/// file and committed its database row. UserDefaults is migration-only.
enum FitnessPendingFITInbox {
    struct Limits: Equatable, Sendable {
        var maximumItems = 50
        var maximumTotalBytes = 256 * 1_024 * 1_024
        var maximumFileBytes = 64 * 1_024 * 1_024
        var maximumFilenameCharacters = 240
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
        let producerBoundaryDidCapture: (() -> Void)?

        init(
            containerURL: URL,
            defaults: UserDefaults? = nil,
            fileManager: FileManager = .default,
            limits: Limits = Limits(),
            producerBoundaryDidCapture: (() -> Void)? = nil
        ) {
            self.containerURL = containerURL
            self.defaults = defaults
            self.fileManager = fileManager
            self.limits = limits
            self.producerBoundaryDidCapture = producerBoundaryDidCapture
        }
    }

    static let suiteName =
        (Bundle.main.object(forInfoDictionaryKey: "HausKlarAppGroup") as? String)
        ?? "group.org.example.hausklar"
    static let queueKey = "hausklar.sharedFitnessFITQueue"
    static let activeIdentityKey = "hausklar.activeFitnessIdentity"
    static let directoryName = "FitnessPendingFIT-v2"
    static let legacyDirectoryName = "FitnessPendingFIT"
    static let readyDirectoryName = "ready"
    static let claimedDirectoryName = "claimed"
    static let temporaryDirectoryName = "temporary"

    private static let metadataFilename = "metadata.json"
    private static let assetFilename = "asset.fit"
    private static let itemSuffix = ".fititem"
    private static let claimMarker = ".claim."
    private static let lockFilename = ".FitnessPendingFIT-v2.lock"
    private static let generationFilename = ".FitnessPendingFIT-v2.generations.json"
    private static let reservationLockFilename = ".reservation.lock"
    private static let maximumMetadataBytes = 64 * 1_024
    private static let maximumGenerationStateBytes = 64 * 1_024
    private static let maximumLegacyQueueBytes = 1_024 * 1_024
    private static let maximumLegacyQueueEntries = 1_024
    private static let generationStateVersion = 1
    private static let unownedGenerationScope = "unowned"
    private static let microsecondClaimPrefix = "us"
    private static let processCoordinationLock = NSLock()
    private static let liveReservations = FitnessPendingFITLiveReservations()
    /// Value-typed and `Sendable`, unlike a shared `ISO8601DateFormatter`.
    /// Producers can enter from the app and share extension concurrently, so a
    /// process-global mutable formatter would otherwise be an unsafe data race.
    private static let dateFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )

    private struct StoredItem: Codable, Equatable {
        let version: Int
        let id: String
        let assetFilename: String
        let originalFilename: String
        let byteCount: Int
        let sha256: String
        let createdAt: String
        let reservationExpiresAt: String?
        var ownerIdentity: String?
    }

    private struct LocatedItem {
        let directory: URL
        let item: StoredItem
        let createdAt: Date
    }

    private struct LocatedReservation {
        let directory: URL
        let item: StoredItem
    }

    private struct GenerationState: Codable {
        let version: Int
        var activeIdentity: String?
        var generations: [String: String]
    }

    private struct ProducerBoundary {
        let identity: String?
        let generation: String
    }

    private struct LegacyMigrationSnapshot {
        let entry: SharedFitnessFITPayload
        let sourceURL: URL
        let filename: String
        let createdAt: Date
        let boundary: ProducerBoundary
    }

    private struct LegacyPublishedDuplicateSnapshot {
        let entry: SharedFitnessFITPayload
        let sourceURL: URL
        let sourceFingerprint: FitnessPendingFITAssetFingerprint
        let durableDirectory: URL
        let durableFingerprint: FitnessPendingFITAssetFingerprint
        let expectedSHA256: String
        let boundary: ProducerBoundary
    }

    private enum LegacyMigrationPreparation {
        case unavailable
        case cleanedPublishedDuplicate
        case verifyPublishedDuplicate(LegacyPublishedDuplicateSnapshot)
        case migrate(LegacyMigrationSnapshot)
    }

    // MARK: Identity boundary

    static func setActiveIdentity(_ identity: String) throws {
        try transitionActiveIdentity(
            to: identity,
            defaults: UserDefaults(suiteName: suiteName),
            containerURL: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            ),
            fileManager: .default
        )
    }

    static func setActiveIdentity(_ identity: String, context: Context) throws {
        try withCoordination(context) {
            try setActiveIdentityLocked(identity, context: context)
        }
    }

    private static func setActiveIdentityLocked(
        _ identity: String,
        context: Context
    ) throws {
        guard isValidIdentity(identity) else {
            throw FitnessPendingFITInboxError.inactiveIdentity
        }
        var state = try readGenerationStateLocked(context: context)
        let mirroredIdentity = context.defaults?.string(forKey: activeIdentityKey)
        if state.activeIdentity != identity || mirroredIdentity != identity {
            // A missing/mismatched mirror means an earlier account transition
            // was interrupted. Rotate even for the same owner so older work
            // cannot become valid again when the mirror is restored.
            state.generations[generationScope(for: state.activeIdentity)] =
                UUID().uuidString.lowercased()
            state.activeIdentity = identity
        }
        let activeScope = generationScope(for: identity)
        if state.generations[activeScope] == nil {
            state.generations[activeScope] = UUID().uuidString.lowercased()
        }
        try writeGenerationStateLocked(state, context: context)
        context.defaults?.set(identity, forKey: activeIdentityKey)
    }

    private static func transitionActiveIdentity(
        to identity: String,
        defaults: UserDefaults?,
        containerURL: URL?,
        fileManager: FileManager
    ) throws {
        guard let containerURL else {
            // A defaults-only owner is not a cross-process identity boundary.
            defaults?.removeObject(forKey: activeIdentityKey)
            fitnessPendingFITInboxLogger.fault(
                "The Fitness identity was not activated because its durable container is unavailable."
            )
            throw FitnessPendingFITInboxError.containerUnavailable
        }
        let context = Context(
            containerURL: containerURL,
            defaults: defaults,
            fileManager: fileManager
        )
        do {
            try withCoordination(context) {
                try setActiveIdentityLocked(identity, context: context)
            }
        } catch {
            // Fail closed: if the durable boundary cannot advance, do not expose
            // the new owner to producers or consumers using this shared state.
            defaults?.removeObject(forKey: activeIdentityKey)
            fitnessPendingFITInboxLogger.fault(
                "The Fitness identity boundary could not be advanced: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    static func clearActiveIdentity() {
        transitionToInactiveIdentity(
            defaults: UserDefaults(suiteName: suiteName),
            containerURL: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            ),
            fileManager: .default
        )
    }

    static func clearActiveIdentity(context: Context) throws {
        try withCoordination(context) {
            try clearActiveIdentityLocked(context: context)
        }
    }

    private static func clearActiveIdentityLocked(context: Context) throws {
        var state = try readGenerationStateLocked(context: context)
        state.generations[generationScope(for: state.activeIdentity)] =
            UUID().uuidString.lowercased()
        state.activeIdentity = nil
        try writeGenerationStateLocked(state, context: context)
        context.defaults?.removeObject(forKey: activeIdentityKey)
    }

    private static func transitionToInactiveIdentity(
        defaults: UserDefaults?,
        containerURL: URL?,
        fileManager: FileManager
    ) {
        guard let containerURL else {
            defaults?.removeObject(forKey: activeIdentityKey)
            fitnessPendingFITInboxLogger.fault(
                "The Fitness identity defaults were cleared, but its durable container is unavailable."
            )
            return
        }
        let context = Context(
            containerURL: containerURL,
            defaults: defaults,
            fileManager: fileManager
        )
        do {
            try withCoordination(context) {
                try clearActiveIdentityLocked(context: context)
            }
        } catch {
            // A mismatch between defaults and durable state blocks inferred
            // producers even if advancing the durable boundary failed.
            defaults?.removeObject(forKey: activeIdentityKey)
            fitnessPendingFITInboxLogger.fault(
                "The cleared Fitness identity generation could not be advanced: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Producer

    @discardableResult
    static func enqueueFIT(
        at sourceURL: URL,
        originalFilename: String? = nil,
        ownerIdentity: String? = nil,
        context: Context? = nil,
        now: Date = Date()
    ) throws -> String {
        let context = try resolvedContext(context)
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
        let values = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .nameKey,
        ])
        guard sourceURL.pathExtension.lowercased() == "fit",
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= context.limits.maximumFileBytes else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        let filename = try validatedFilename(
            originalFilename ?? values.name ?? sourceURL.lastPathComponent,
            limits: context.limits
        )
        let boundary = try withCoordination(context) {
            try prepareAndReconcileLocked(context: context, now: now)
            try assertCapacity(addingByteCount: byteCount, context: context)
            return try captureProducerBoundaryLocked(
                owner: ownerIdentity,
                context: context
            )
        }
        context.producerBoundaryDidCapture?()
        let item = try makeStoredItem(
            id: UUID().uuidString,
            sourceURL: sourceURL,
            originalFilename: filename,
            byteCount: byteCount,
            ownerIdentity: boundary.identity,
            context: context,
            now: now
        )
        let reservation = try withCoordination(context) {
            try validateProducerBoundaryLocked(
                boundary,
                context: context
            )
            try prepareAndReconcileLocked(context: context, now: now)
            try assertCapacity(addingByteCount: item.byteCount, context: context)
            return try reserveStageLocked(item: item, context: context)
        }
        let staged = reservation.directory
        defer { liveReservations.remove(staged) }
        do {
            try populateReservedStage(
                item: item,
                sourceURL: sourceURL,
                directory: staged,
                context: context
            )
            try withCoordination(context) {
                try validateProducerBoundaryLocked(
                    boundary,
                    context: context
                )
                try prepareAndReconcileLocked(
                    context: context,
                    now: now,
                    preservingTemporary: staged
                )
                try assertCapacity(
                    addingByteCount: item.byteCount,
                    excludingTemporaryDirectory: staged,
                    context: context
                )
                let destination = readyDirectory(context).appendingPathComponent(
                    readyName(id: item.id), isDirectory: true
                )
                guard !context.fileManager.fileExists(atPath: destination.path) else {
                    throw FitnessPendingFITInboxError.coordinationFailed
                }
                try reservation.finishBeforePublishing()
                try atomicRename(staged, destination)
            }
            return item.id
        } catch {
            if context.fileManager.fileExists(atPath: staged.path) {
                do {
                    try context.fileManager.removeItem(at: staged)
                } catch {
                    fitnessPendingFITInboxLogger.error(
                        "Failed to clean an unpublished FIT staging directory; reconciliation will retry: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
    }

    // MARK: Claims

    static func claimNextOwned(
        for identity: String,
        excluding excludedIDs: Set<String> = [],
        context: Context? = nil,
        now: Date = Date()
    ) throws -> FitnessPendingFITClaim? {
        let context = try resolvedContext(context)
        try migrateLegacyEntries(
            ownerIdentity: identity,
            requiredActiveIdentity: identity,
            context: context
        )
        var rejectedIDs = excludedIDs
        while true {
            let claim: FitnessPendingFITClaim? = try withCoordination(context) {
                try requireActiveIdentity(identity, context: context)
                try prepareAndReconcileLocked(context: context, now: now)
                let valid = try validItems(
                    in: readyDirectory(context),
                    context: context
                )
                let items = valid.sorted { left, right in
                    left.createdAt == right.createdAt
                        ? left.item.id < right.item.id
                        : left.createdAt < right.createdAt
                }
                guard let candidate = items.first(where: {
                    $0.item.ownerIdentity == identity && !rejectedIDs.contains($0.item.id)
                }) else { return nil }
                return try claimLocked(
                    candidate,
                    identity: identity,
                    context: context,
                    now: now
                )
            }
            guard let claim else { return nil }
            if let verified = try verifyClaimForDelivery(claim, context: context) {
                return verified
            }
            rejectedIDs.insert(claim.payload.id)
        }
    }

    static func claim(
        id: String,
        for identity: String,
        allowUnowned: Bool,
        context: Context? = nil,
        now: Date = Date()
    ) throws -> FitnessPendingFITClaim? {
        let context = try resolvedContext(context)
        try migrateLegacyEntries(
            ownerIdentity: identity,
            specificID: id,
            requiredActiveIdentity: identity,
            context: context
        )
        if allowUnowned {
            try migrateLegacyEntries(
                ownerIdentity: nil,
                specificID: id,
                requiredActiveIdentity: identity,
                context: context
            )
        }
        let claim: FitnessPendingFITClaim? = try withCoordination(context) {
            try requireActiveIdentity(identity, context: context)
            try prepareAndReconcileLocked(context: context, now: now)
            guard let candidate = try validItems(in: readyDirectory(context), context: context)
                .first(where: { $0.item.id == id }) else { return nil }
            guard candidate.item.ownerIdentity == identity
                    || (allowUnowned && candidate.item.ownerIdentity == nil) else {
                return nil
            }
            return try claimLocked(candidate, identity: identity, context: context, now: now)
        }
        guard let claim else { return nil }
        return try verifyClaimForDelivery(claim, context: context)
    }

    static func acknowledge(
        _ claim: FitnessPendingFITClaim,
        context: Context? = nil
    ) throws {
        let context = try resolvedContext(context)
        try withCoordination(context) {
            let directory = try verifiedClaimDirectory(claim, context: context)
            guard context.fileManager.fileExists(atPath: directory.path) else {
                throw FitnessPendingFITInboxError.staleClaim
            }
            let item = try readAndValidateItem(at: directory, context: context)
            guard item.id == claim.payload.id,
                  let expectedFingerprint = claim.verifiedAssetFingerprint,
                  try assetFingerprint(
                    directory.appendingPathComponent(assetFilename)
                  ) == expectedFingerprint else {
                throw FitnessPendingFITInboxError.staleClaim
            }
            try context.fileManager.removeItem(at: directory)
        }
    }

    @discardableResult
    static func release(
        _ claim: FitnessPendingFITClaim,
        context: Context? = nil
    ) throws -> Bool {
        let context = try resolvedContext(context)
        return try withCoordination(context) {
            let directory = try verifiedClaimDirectory(claim, context: context)
            guard context.fileManager.fileExists(atPath: directory.path) else { return false }
            let item = try readAndValidateItem(at: directory, context: context)
            guard item.id == claim.payload.id,
                  let expectedFingerprint = claim.verifiedAssetFingerprint,
                  try assetFingerprint(
                    directory.appendingPathComponent(assetFilename)
                  ) == expectedFingerprint else {
                throw FitnessPendingFITInboxError.staleClaim
            }
            let destination = readyDirectory(context).appendingPathComponent(
                readyName(id: item.id), isDirectory: true
            )
            guard !context.fileManager.fileExists(atPath: destination.path) else {
                throw FitnessPendingFITInboxError.coordinationFailed
            }
            try atomicRename(directory, destination)
            return true
        }
    }

    // MARK: Inspection, reconciliation and purge

    @discardableResult
    static func reconcile(context: Context? = nil, now: Date = Date()) throws -> Int {
        let context = try resolvedContext(context)
        return try withCoordination(context) {
            try prepareAndReconcileLocked(context: context, now: now)
        }
    }

    static func unownedEntries(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) -> [SharedFitnessFITPayload] {
        recoveryEntries(
            defaults: defaults,
            containerURL: containerURL,
            fileManager: fileManager
        ).filter { $0.ownerIdentity == nil }
    }

    static func ownedRecoveryEntries(
        identity: String,
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) -> [SharedFitnessFITPayload] {
        recoveryEntries(
            defaults: defaults,
            containerURL: containerURL,
            fileManager: fileManager
        ).filter { $0.ownerIdentity == identity }
    }

    static func pendingCount(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) -> Int {
        recoveryEntries(
            defaults: defaults,
            containerURL: containerURL,
            fileManager: fileManager
        ).count
    }

    static func pendingCount(
        identity: String,
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) -> Int {
        recoveryEntries(
            defaults: defaults,
            containerURL: containerURL,
            fileManager: fileManager
        ).filter { $0.ownerIdentity == identity }.count
    }

    static func purgeOwned(
        identity: String,
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) throws {
        guard let containerURL else {
            throw FitnessPendingFITInboxError.containerUnavailable
        }
        let context = Context(containerURL: containerURL, defaults: defaults, fileManager: fileManager)
        try withCoordination(context) {
            var state = try readGenerationStateLocked(context: context)
            state.generations[generationScope(for: identity)] =
                UUID().uuidString.lowercased()
            if state.activeIdentity == identity { state.activeIdentity = nil }
            try writeGenerationStateLocked(state, context: context)
            if defaults?.string(forKey: activeIdentityKey) == identity {
                defaults?.removeObject(forKey: activeIdentityKey)
            }
            try prepareDirectories(context)
            try purgeOwnedTemporaryLocked(identity: identity, context: context)
            try prepareAndReconcileLocked(
                context: context,
                now: Date(),
                reconcileTemporary: false
            )
            for directory in [readyDirectory(context), claimedDirectory(context)] {
                for located in try validItems(in: directory, context: context)
                    where located.item.ownerIdentity == identity {
                    try fileManager.removeItem(at: located.directory)
                }
            }
            try purgeOwnedLegacy(identity: identity, context: context)
        }
    }

    static func purgeUnclaimed(
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) throws {
        guard let containerURL else {
            throw FitnessPendingFITInboxError.containerUnavailable
        }
        let context = Context(containerURL: containerURL, defaults: defaults, fileManager: fileManager)
        try withCoordination(context) {
            try resetGenerationsLocked(context: context)
            defaults?.removeObject(forKey: activeIdentityKey)
            defaults?.removeObject(forKey: queueKey)
            for name in [directoryName, legacyDirectoryName] {
                let directory = containerURL.appendingPathComponent(name, isDirectory: true)
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
            }
        }
    }

    private static func recoveryEntries(
        defaults: UserDefaults?,
        containerURL: URL?,
        fileManager: FileManager
    ) -> [SharedFitnessFITPayload] {
        var durable: [SharedFitnessFITPayload] = []
        if let containerURL {
            let context = Context(
                containerURL: containerURL,
                defaults: defaults,
                fileManager: fileManager
            )
            do {
                durable = try withCoordination(context) {
                    try prepareAndReconcileLocked(context: context, now: Date())
                    return try ([readyDirectory(context), claimedDirectory(context)]
                        .flatMap { try validItems(in: $0, context: context) })
                        .map { try payload(for: $0.item, in: $0.directory, context: context) }
                }
            } catch {
                fitnessPendingFITInboxLogger.error(
                    "Durable FIT recovery entries could not be inspected: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        let durableIDs = Set(durable.map(\.id))
        return (durable + legacyEntries(defaults: defaults).filter { !durableIDs.contains($0.id) })
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: Filesystem implementation

    private static func resolvedContext(_ context: Context?) throws -> Context {
        if let context { return context }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ) else { throw FitnessPendingFITInboxError.containerUnavailable }
        return Context(
            containerURL: containerURL,
            defaults: UserDefaults(suiteName: suiteName)
        )
    }

    private static func rootDirectory(_ context: Context) -> URL {
        context.containerURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func readyDirectory(_ context: Context) -> URL {
        rootDirectory(context).appendingPathComponent(readyDirectoryName, isDirectory: true)
    }

    private static func claimedDirectory(_ context: Context) -> URL {
        rootDirectory(context).appendingPathComponent(claimedDirectoryName, isDirectory: true)
    }

    private static func temporaryDirectory(_ context: Context) -> URL {
        rootDirectory(context).appendingPathComponent(temporaryDirectoryName, isDirectory: true)
    }

    private static func prepareDirectories(_ context: Context) throws {
        for directory in [
            rootDirectory(context), readyDirectory(context),
            claimedDirectory(context), temporaryDirectory(context),
        ] {
            try context.fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            let values = try directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FitnessPendingFITInboxError.coordinationFailed
            }
            try context.fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
        }
    }

    private static func withCoordination<T>(
        _ context: Context,
        _ operation: () throws -> T
    ) throws -> T {
        processCoordinationLock.lock()
        defer { processCoordinationLock.unlock() }
        try context.fileManager.createDirectory(
            at: context.containerURL,
            withIntermediateDirectories: true
        )
        let lockURL = context.containerURL.appendingPathComponent(lockFilename)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw FitnessPendingFITInboxError.coordinationFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static func generationScope(for identity: String?) -> String {
        guard let identity else { return unownedGenerationScope }
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString.lowercased()
    }

    private static func isValidIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
    }

    private static func generationStateURL(_ context: Context) -> URL {
        context.containerURL.appendingPathComponent(generationFilename)
    }

    private static func captureProducerBoundaryLocked(
        owner: String?,
        context: Context
    ) throws -> ProducerBoundary {
        var state = try readGenerationStateLocked(context: context)
        guard state.activeIdentity
                == context.defaults?.string(forKey: activeIdentityKey),
              owner == nil || owner == state.activeIdentity else {
            throw FitnessPendingFITInboxError.inactiveIdentity
        }
        let identity = state.activeIdentity
        let scope = generationScope(for: identity)
        let generation: String
        if let existing = state.generations[scope] {
            generation = existing
        } else {
            generation = UUID().uuidString.lowercased()
            state.generations[scope] = generation
            try writeGenerationStateLocked(state, context: context)
        }
        return ProducerBoundary(
            identity: identity,
            generation: generation
        )
    }

    private static func validateProducerBoundaryLocked(
        _ boundary: ProducerBoundary,
        context: Context
    ) throws {
        let state = try readGenerationStateLocked(context: context)
        guard state.generations[generationScope(for: boundary.identity)]
                == boundary.generation,
              state.activeIdentity == boundary.identity,
              context.defaults?.string(forKey: activeIdentityKey)
                == boundary.identity else {
            throw FitnessPendingFITInboxError.inactiveIdentity
        }
    }

    private static func resetGenerationsLocked(context: Context) throws {
        try writeGenerationStateLocked(
            GenerationState(
                version: generationStateVersion,
                activeIdentity: nil,
                generations: [:]
            ),
            context: context
        )
    }

    private static func readGenerationStateLocked(context: Context) throws -> GenerationState {
        let url = generationStateURL(context)
        guard !(try pathIsAbsent(url)) else {
            // One-time migration: before the durable state exists, bootstrap
            // the active identity that the previous build stored in the suite.
            let mirroredIdentity = context.defaults?.string(forKey: activeIdentityKey)
            return GenerationState(
                version: generationStateVersion,
                activeIdentity: mirroredIdentity.flatMap {
                    isValidIdentity($0) ? $0 : nil
                },
                generations: [:]
            )
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= maximumGenerationStateBytes else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let state = try JSONDecoder().decode(
            GenerationState.self,
            from: Data(contentsOf: url, options: [.mappedIfSafe])
        )
        guard state.version == generationStateVersion,
              state.activeIdentity.map(isValidIdentity) ?? true,
              state.generations.count <= 1_024,
              state.generations.allSatisfy({ scope, generation in
                  (scope == unownedGenerationScope
                    || isCanonicalSHA256(scope))
                    && isCanonicalLowercaseUUID(generation)
              }) else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        return state
    }

    private static func writeGenerationStateLocked(
        _ state: GenerationState,
        context: Context
    ) throws {
        guard state.version == generationStateVersion,
              state.activeIdentity.map(isValidIdentity) ?? true,
              state.generations.count <= 1_024,
              state.generations.allSatisfy({ scope, generation in
                  (scope == unownedGenerationScope || isCanonicalSHA256(scope))
                      && isCanonicalLowercaseUUID(generation)
              }) else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard !data.isEmpty, data.count <= maximumGenerationStateBytes else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let destination = generationStateURL(context)
        let temporary = context.containerURL.appendingPathComponent(
            ".\(generationFilename).\(UUID().uuidString.lowercased()).tmp"
        )
        do {
            try data.write(to: temporary, options: [.completeFileProtection])
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                let synchronizationError = error
                do {
                    try handle.close()
                } catch {
                    fitnessPendingFITInboxLogger.error(
                        "Failed to close a generation state file after synchronization failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                throw synchronizationError
            }
            try atomicRename(temporary, destination)
            let directoryDescriptor = open(context.containerURL.path, O_RDONLY)
            guard directoryDescriptor >= 0 else {
                throw FitnessPendingFITInboxError.coordinationFailed
            }
            defer { close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if context.fileManager.fileExists(atPath: temporary.path) {
                do {
                    try context.fileManager.removeItem(at: temporary)
                } catch {
                    fitnessPendingFITInboxLogger.error(
                        "Failed to remove an unpublished generation state: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
    }

    @discardableResult
    private static func prepareAndReconcileLocked(
        context: Context,
        now: Date,
        preservingTemporary: URL? = nil,
        reconcileTemporary: Bool = true
    ) throws -> Int {
        try prepareDirectories(context)
        var recovered = 0
        let candidateLimit = max(1, context.limits.maximumReconciliationCandidates)
        let mutationLimit = max(1, context.limits.maximumReconciliationMutations)
        if reconcileTemporary {
            let temporaryRoot = temporaryDirectory(context).standardizedFileURL
            let temporary = try boundedDirectDirectories(
                in: temporaryRoot,
                limit: candidateLimit,
                context: context,
                where: {
                    isSafeDirectDirectory($0, parent: temporaryRoot)
                        && isTemporaryStageName($0.lastPathComponent)
                },
                sortedBy: {
                    reconciliationDate($0) == reconciliationDate($1)
                        ? $0.lastPathComponent < $1.lastPathComponent
                        : reconciliationDate($0) < reconciliationDate($1)
                }
            )
            let preservedTemporary = preservingTemporary?.standardizedFileURL
            for item in temporary {
                guard recovered < mutationLimit else { break }
                guard item.standardizedFileURL != preservedTemporary else { continue }
                do {
                    if try reservationIsLive(item) { continue }
                } catch {
                    fitnessPendingFITInboxLogger.error(
                        "Could not probe a FIT reservation lease; it was retained: \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
                let modified = reconciliationDate(item)
                guard isSafeDirectDirectory(item, parent: temporaryRoot),
                      isTemporaryStageName(item.lastPathComponent),
                      modified != .distantPast else {
                    continue
                }
                do {
                    let metadata = try readAndValidateMetadata(at: item, context: context)
                    if let encodedExpiry = metadata.reservationExpiresAt {
                        guard try validatedCreatedDate(encodedExpiry) <= now else { continue }
                    } else {
                        guard now.timeIntervalSince(modified)
                                >= context.limits.temporaryLifetime else { continue }
                    }
                } catch where isConfirmedInvalidItemError(error) {
                    guard now.timeIntervalSince(modified)
                            >= context.limits.temporaryLifetime else { continue }
                } catch {
                    fitnessPendingFITInboxLogger.error(
                        "Could not inspect a staged FIT reservation; it was retained: \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
                do {
                    try context.fileManager.removeItem(at: item)
                    recovered += 1
                } catch {
                    continue
                }
            }
        }

        let claimedRoot = claimedDirectory(context).standardizedFileURL
        let claimed = try boundedDirectDirectories(
            in: claimedRoot,
            limit: candidateLimit,
            context: context,
            where: {
                isSafeDirectDirectory($0, parent: claimedRoot)
                    && parseClaimName($0.lastPathComponent) != nil
            },
            sortedBy: {
                claimedReconciliationPriority($0,parent: claimedRoot,now: now)
                    == claimedReconciliationPriority($1,parent: claimedRoot,now: now)
                    ? $0.lastPathComponent < $1.lastPathComponent
                    : claimedReconciliationPriority($0,parent: claimedRoot,now: now)
                        < claimedReconciliationPriority($1,parent: claimedRoot,now: now)
            }
        )
        for directory in claimed {
            guard recovered < mutationLimit else { break }
            guard isSafeDirectDirectory(directory, parent: claimedRoot) else { continue }
            guard let parsed = parseClaimName(directory.lastPathComponent) else { continue }
            let item: StoredItem
            do {
                item = try readAndValidateItem(at: directory, context: context)
            } catch where isConfirmedInvalidItemError(error) {
                do {
                    try context.fileManager.removeItem(at: directory)
                    recovered += 1
                } catch {
                    continue
                }
                continue
            } catch {
                // An unavailable file provider, protection boundary, or other
                // ambiguous I/O failure is not evidence that the private FIT
                // payload is corrupt. Keep it for a later reconciliation pass.
                fitnessPendingFITInboxLogger.error(
                    "Could not inspect a claimed FIT item; it was retained: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            guard item.id == parsed.id else {
                do {
                    try context.fileManager.removeItem(at: directory)
                    recovered += 1
                } catch {
                    continue
                }
                continue
            }
            guard parsed.expiresAt <= now else { continue }
            let destination = readyDirectory(context).appendingPathComponent(
                readyName(id: item.id), isDirectory: true
            )
            do {
                if context.fileManager.fileExists(atPath: destination.path) {
                    guard isSafeDirectDirectory(
                        destination,
                        parent: readyDirectory(context).standardizedFileURL
                    ) else { continue }
                    let existing: StoredItem
                    do {
                        existing = try readAndValidateItem(at: destination, context: context)
                    } catch {
                        fitnessPendingFITInboxLogger.error(
                            "Could not verify an existing ready FIT item; both copies were retained: \(error.localizedDescription, privacy: .public)"
                        )
                        continue
                    }
                    guard existing.id == item.id else { continue }
                    try context.fileManager.removeItem(at: directory)
                } else {
                    guard try pathIsAbsent(destination) else { continue }
                    try atomicRename(directory, destination)
                }
                recovered += 1
            } catch {
                // A validated claim is live private data. Retry on a later pass.
                continue
            }
        }

        let readyRoot = readyDirectory(context).standardizedFileURL
        let readyChildren = try boundedDirectDirectories(
            in: readyRoot,
            limit: candidateLimit,
            context: context,
            where: {
                isSafeDirectDirectory($0, parent: readyRoot)
                    && isReadyDirectoryName($0.lastPathComponent)
            },
            sortedBy: {
                let leftPriority = readyReconciliationPriority($0,parent: readyRoot)
                let rightPriority = readyReconciliationPriority($1,parent: readyRoot)
                return leftPriority == rightPriority
                    ? $0.lastPathComponent < $1.lastPathComponent
                    : leftPriority < rightPriority
            }
        )
        for child in readyChildren {
            guard recovered < mutationLimit else { break }
            guard isSafeDirectDirectory(child, parent: readyRoot) else { continue }
            guard isReadyDirectoryName(child.lastPathComponent) else { continue }
            do {
                _ = try readAndValidateItem(at: child, context: context)
            } catch where isConfirmedInvalidItemError(error) {
                do {
                    try context.fileManager.removeItem(at: child)
                    recovered += 1
                } catch {
                    continue
                }
            } catch {
                fitnessPendingFITInboxLogger.error(
                    "Could not inspect a ready FIT item; it was retained: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return recovered
    }

    /// Removes only reservations whose protected metadata proves exact owner
    /// attribution. Missing, malformed, or unreadable metadata blocks purge so
    /// the caller can retry without risking another owner's staged payload.
    private static func purgeOwnedTemporaryLocked(
        identity: String,
        context: Context
    ) throws {
        let root = temporaryDirectory(context).standardizedFileURL
        var enumerationError: Error?
        guard let enumerator = context.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        while let child = enumerator.nextObject() as? URL {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == root,
                  isTemporaryStageName(candidate.lastPathComponent) else {
                continue
            }
            let item = try readAndValidateMetadata(at: candidate, context: context)
            if item.ownerIdentity == identity {
                try context.fileManager.removeItem(at: candidate)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    private static func makeStoredItem(
        id: String,
        sourceURL: URL,
        originalFilename: String,
        byteCount: Int,
        ownerIdentity: String?,
        context: Context,
        now: Date
    ) throws -> StoredItem {
        guard UUID(uuidString: id) != nil,
              context.limits.temporaryLifetime.isFinite,
              context.limits.temporaryLifetime > 0 else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        let createdAt = dateFormat.format(now)
        let reservationExpiresAt = dateFormat.format(
            now.addingTimeInterval(context.limits.temporaryLifetime)
        )
        _ = try validatedCreatedDate(createdAt)
        _ = try validatedCreatedDate(reservationExpiresAt)
        return StoredItem(
            version: 2,
            id: id,
            assetFilename: assetFilename,
            originalFilename: originalFilename,
            byteCount: byteCount,
            sha256: try sha256(of: sourceURL),
            createdAt: createdAt,
            reservationExpiresAt: reservationExpiresAt,
            ownerIdentity: ownerIdentity
        )
    }

    private static func reserveStageLocked(
        item: StoredItem,
        context: Context
    ) throws -> FitnessPendingFITReservationLease {
        let directory = temporaryDirectory(context).appendingPathComponent(
            ".stage-\(item.id)-\(UUID().uuidString.lowercased())", isDirectory: true
        )
        try context.fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try writeMetadata(item, to: directory, context: context)
            try context.fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
            let lockURL = directory.appendingPathComponent(reservationLockFilename)
            let descriptor = open(
                lockURL.path,
                O_CREAT | O_RDWR | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if descriptor >= 0 { close(descriptor) }
                throw FitnessPendingFITInboxError.coordinationFailed
            }
            let lease = FitnessPendingFITReservationLease(
                directory: directory,
                lockURL: lockURL,
                descriptor: descriptor
            )
            do {
                try context.fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: lockURL.path
                )
            } catch {
                lease.cancel()
                throw error
            }
            liveReservations.insert(directory)
            return lease
        } catch {
            do {
                try context.fileManager.removeItem(at: directory)
            } catch {
                fitnessPendingFITInboxLogger.error(
                    "Failed to clean an unreserved FIT staging directory: \(error.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
    }

    private static func populateReservedStage(
        item: StoredItem,
        sourceURL: URL,
        directory: URL,
        context: Context
    ) throws {
        let asset = directory.appendingPathComponent(assetFilename)
        try context.fileManager.copyItem(at: sourceURL, to: asset)
        try protectRecursively(directory, context: context)
        _ = try readAndVerifyItem(at: directory, context: context)
    }

    private static func claimLocked(
        _ located: LocatedItem,
        identity: String,
        context: Context,
        now: Date
    ) throws -> FitnessPendingFITClaim {
        let leaseID = UUID().uuidString.lowercased()
        guard context.limits.claimLifetime.isFinite,
              context.limits.claimLifetime > 0 else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let expiry = try encodedClaimExpiry(
            now.addingTimeInterval(context.limits.claimLifetime)
        )
        let destination = claimedDirectory(context).appendingPathComponent(
            claimName(
                id: located.item.id,
                encodedExpiry: expiry.component,
                leaseID: leaseID
            ),
            isDirectory: true
        )
        try atomicRename(located.directory, destination)
        var claimed = located.item
        if claimed.ownerIdentity == nil {
            claimed.ownerIdentity = identity
            do {
                try writeMetadata(claimed, to: destination, context: context)
            } catch {
                let metadataError = error
                do {
                    try atomicRename(destination, located.directory)
                } catch {
                    fitnessPendingFITInboxLogger.fault(
                        "FIT claim metadata failed and its claim could not be released. Metadata error: \(metadataError.localizedDescription, privacy: .public). Release error: \(error.localizedDescription, privacy: .public)"
                    )
                    throw FitnessPendingFITInboxError.claimRecoveryFailed
                }
                throw metadataError
            }
        }
        return FitnessPendingFITClaim(
            leaseID: leaseID,
            expiresAt: expiry.date,
            payload: try payload(for: claimed, in: destination, context: context),
            claimedDirectoryPath: destination.path,
            verifiedAssetFingerprint: nil
        )
    }

    private static func validItems(
        in directory: URL,
        context: Context
    ) throws -> [LocatedItem] {
        let parent = directory.standardizedFileURL
        let expectsReadyName = parent == readyDirectory(context).standardizedFileURL
        let candidates = try boundedDirectDirectories(
            in: parent,
            limit: max(1, context.limits.maximumReconciliationCandidates),
            context: context,
            where: {
                expectsReadyName
                    ? isReadyDirectoryName($0.lastPathComponent)
                    : parseClaimName($0.lastPathComponent) != nil
            },
            sortedBy: { $0.lastPathComponent < $1.lastPathComponent },
            failIfTruncated: true
        )
        var valid: [LocatedItem] = []
        valid.reserveCapacity(candidates.count)
        for child in candidates {
            do {
                let item = try readAndValidateItem(at: child, context: context)
                valid.append(LocatedItem(
                    directory: child,
                    item: item,
                    createdAt: try validatedCreatedDate(item.createdAt)
                ))
            } catch where isConfirmedInvalidItemError(error) {
                // Reconciliation quarantines/removes confirmed-invalid records.
                // They are not live capacity, but ambiguous I/O must propagate.
                try context.fileManager.removeItem(at: child)
                continue
            }
        }
        return valid
    }

    private static func validTemporaryReservations(
        context: Context
    ) throws -> [LocatedReservation] {
        let parent = temporaryDirectory(context).standardizedFileURL
        let candidates = try boundedDirectDirectories(
            in: parent,
            limit: max(1, context.limits.maximumReconciliationCandidates),
            context: context,
            where: { isTemporaryStageName($0.lastPathComponent) },
            sortedBy: { $0.lastPathComponent < $1.lastPathComponent },
            failIfTruncated: true
        )
        var reservations: [LocatedReservation] = []
        reservations.reserveCapacity(candidates.count)
        for candidate in candidates {
            do {
                reservations.append(LocatedReservation(
                    directory: candidate,
                    item: try readAndValidateMetadata(at: candidate, context: context)
                ))
            } catch where isConfirmedInvalidItemError(error) {
                // Ownership and reserved bytes cannot be established safely.
                // Reconciliation may remove it only after its stale threshold.
                throw FitnessPendingFITInboxError.coordinationFailed
            }
        }
        return reservations
    }

    private static func validLegacyCapacityEntries(
        excluding excludedEntry: SharedFitnessFITPayload?,
        context: Context
    ) throws -> [SharedFitnessFITPayload] {
        var didExclude = false
        var valid: [SharedFitnessFITPayload] = []
        for entry in try decodedLegacyEntries(defaults: context.defaults) {
            if !didExclude, let excludedEntry, entry == excludedEntry {
                didExclude = true
                continue
            }
            do {
                _ = try validateLegacyEntry(entry, context: context, allowMissingSource: false)
                valid.append(entry)
            } catch where isConfirmedInvalidItemError(error) {
                // The bytes/owner cannot be inventoried safely, so quota must
                // remain closed until recovery or an explicit privacy purge.
                throw FitnessPendingFITInboxError.coordinationFailed
            }
        }
        return valid
    }

    private static func readAndValidateItem(at directory: URL, context: Context) throws -> StoredItem {
        let item = try readAndValidateMetadata(at: directory, context: context)
        let asset = directory.appendingPathComponent(assetFilename)
        let values = try asset.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              values.fileSize == item.byteCount else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        return item
    }

    private static func readAndVerifyItem(at directory: URL, context: Context) throws -> StoredItem {
        let item = try readAndValidateItem(at: directory, context: context)
        guard try sha256(of: directory.appendingPathComponent(assetFilename))
                == item.sha256 else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        return item
    }

    private static func readAndValidateMetadata(
        at directory: URL,
        context: Context
    ) throws -> StoredItem {
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        let metadata = directory.appendingPathComponent(metadataFilename)
        let metadataValues = try metadata.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard metadataValues.isRegularFile == true,
              metadataValues.isSymbolicLink != true,
              let metadataBytes = metadataValues.fileSize,
              metadataBytes > 0,
              metadataBytes <= maximumMetadataBytes else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        let item = try JSONDecoder().decode(
            StoredItem.self,
            from: Data(contentsOf: metadata, options: [.mappedIfSafe])
        )
        let directoryName = directory.lastPathComponent
        let directoryMatchesItem = directoryName == readyName(id: item.id)
            || parseClaimName(directoryName)?.id == item.id
            || (isTemporaryStageName(directoryName)
                && directoryName.hasPrefix(".stage-\(item.id)-"))
        guard item.version == 2,
              UUID(uuidString: item.id) != nil,
              directoryMatchesItem,
              item.assetFilename == assetFilename,
              item.byteCount > 0,
              item.byteCount <= context.limits.maximumFileBytes,
              isCanonicalSHA256(item.sha256),
              item.ownerIdentity.map(isValidIdentity) ?? true,
              try validatedFilename(item.originalFilename, limits: context.limits)
                == item.originalFilename else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        _ = try validatedCreatedDate(item.createdAt)
        if let reservationExpiresAt = item.reservationExpiresAt {
            _ = try validatedCreatedDate(reservationExpiresAt)
        }
        return item
    }

    private static func writeMetadata(
        _ item: StoredItem,
        to directory: URL,
        context: Context
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(item).write(
            to: directory.appendingPathComponent(metadataFilename),
            options: [.atomic, .completeFileProtection]
        )
    }

    private static func payload(
        for item: StoredItem,
        in directory: URL,
        context: Context
    ) throws -> SharedFitnessFITPayload {
        _ = try readAndValidateItem(at: directory, context: context)
        return SharedFitnessFITPayload(
            id: item.id,
            filePath: directory.appendingPathComponent(assetFilename).path,
            originalFilename: item.originalFilename,
            byteCount: item.byteCount,
            createdAt: item.createdAt,
            ownerIdentity: item.ownerIdentity
        )
    }

    private static func assertCapacity(
        addingByteCount byteCount: Int,
        excludingTemporaryDirectory: URL? = nil,
        excludingLegacyEntry: SharedFitnessFITPayload? = nil,
        context: Context
    ) throws {
        let durable = try ([readyDirectory(context), claimedDirectory(context)]
            .flatMap { try validItems(in: $0, context: context) })
        let excludedPath = excludingTemporaryDirectory?.standardizedFileURL.path
        let reservations = try validTemporaryReservations(context: context).filter {
            $0.directory.standardizedFileURL.path != excludedPath
        }
        let legacy = try validLegacyCapacityEntries(
            excluding: excludingLegacyEntry,
            context: context
        )
        let existingCount = durable.count + reservations.count + legacy.count
        let existingBytes = durable.reduce(0) { $0 + $1.item.byteCount }
            + reservations.reduce(0) { $0 + $1.item.byteCount }
            + legacy.reduce(0) { $0 + $1.byteCount }
        guard existingCount < context.limits.maximumItems,
              existingBytes + byteCount
                <= context.limits.maximumTotalBytes else {
            throw FitnessPendingFITInboxError.inboxFull
        }
    }

    private static func verifiedClaimDirectory(
        _ claim: FitnessPendingFITClaim,
        context: Context
    ) throws -> URL {
        let directory = URL(fileURLWithPath: claim.claimedDirectoryPath).standardizedFileURL
        guard directory.deletingLastPathComponent() == claimedDirectory(context).standardizedFileURL,
              let parsed = parseClaimName(directory.lastPathComponent),
              parsed.id == claim.payload.id,
              parsed.leaseID == claim.leaseID,
              parsed.expiresAt == claim.expiresAt else {
            throw FitnessPendingFITInboxError.staleClaim
        }
        return directory
    }

    private static func verifyClaimForDelivery(
        _ claim: FitnessPendingFITClaim,
        context: Context
    ) throws -> FitnessPendingFITClaim? {
        let directory = try verifiedClaimDirectory(claim, context: context)
        do {
            let asset = directory.appendingPathComponent(assetFilename)
            let fingerprintBeforeVerification = try assetFingerprint(asset)
            let item = try readAndVerifyItem(at: directory, context: context)
            let fingerprintAfterVerification = try assetFingerprint(asset)
            guard item.id == claim.payload.id,
                  fingerprintBeforeVerification == fingerprintAfterVerification else {
                throw FitnessPendingFITInboxError.invalidFile
            }
            var verified = claim
            verified.verifiedAssetFingerprint = fingerprintAfterVerification
            return verified
        } catch where isConfirmedInvalidItemError(error) {
            try withCoordination(context) {
                let exactDirectory = try verifiedClaimDirectory(claim, context: context)
                guard !(try pathIsAbsent(exactDirectory)) else { return }
                try context.fileManager.removeItem(at: exactDirectory)
            }
            return nil
        }
    }

    private static func assetFingerprint(
        _ asset: URL
    ) throws -> FitnessPendingFITAssetFingerprint {
        var information = stat()
        guard lstat(asset.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (information.st_mode & S_IFMT) == S_IFREG else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        return FitnessPendingFITAssetFingerprint(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            byteCount: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }

    private static func requireActiveIdentity(_ identity: String, context: Context) throws {
        let state = try readGenerationStateLocked(context: context)
        guard state.activeIdentity == identity,
              context.defaults?.string(forKey: activeIdentityKey) == identity else {
            throw FitnessPendingFITInboxError.inactiveIdentity
        }
    }

    private static func readyName(id: String) -> String { "\(id)\(itemSuffix)" }

    private static func encodedClaimExpiry(
        _ requestedDate: Date
    ) throws -> (component: String, date: Date) {
        let microseconds = requestedDate.timeIntervalSince1970 * 1_000_000
        guard microseconds.isFinite,
              microseconds > Double(Int64.min),
              microseconds < Double(Int64.max) else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let canonicalMicroseconds = Int64(microseconds.rounded())
        return (
            "\(microsecondClaimPrefix)\(canonicalMicroseconds)",
            Date(timeIntervalSince1970: Double(canonicalMicroseconds) / 1_000_000)
        )
    }

    private static func claimName(
        id: String,
        encodedExpiry: String,
        leaseID: String
    ) -> String {
        "\(readyName(id: id))\(claimMarker)\(encodedExpiry).\(leaseID)"
    }

    private static func parseClaimName(
        _ name: String
    ) -> (id: String, expiresAt: Date, leaseID: String)? {
        let parts = name.components(separatedBy: claimMarker)
        guard parts.count == 2,
              parts[0].hasSuffix(itemSuffix),
              isReadyDirectoryName(parts[0]) else { return nil }
        let id = String(parts[0].dropLast(itemSuffix.count))
        let claim = parts[1].split(separator: ".", maxSplits: 1).map(String.init)
        guard claim.count == 2, UUID(uuidString: claim[1]) != nil else { return nil }
        let expiresAt: Date
        if claim[0].hasPrefix(microsecondClaimPrefix) {
            let encodedMicroseconds = claim[0].dropFirst(microsecondClaimPrefix.count)
            guard let microseconds = Int64(encodedMicroseconds),
                  claim[0] == "\(microsecondClaimPrefix)\(microseconds)" else {
                return nil
            }
            expiresAt = Date(
                timeIntervalSince1970: Double(microseconds) / 1_000_000
            )
        } else {
            // Compatibility with claims published by v2 builds that encoded
            // whole seconds. New claims always use canonical microseconds.
            guard let timestamp = Int64(claim[0]),
                  claim[0] == String(timestamp) else { return nil }
            expiresAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
        }
        return (
            id,
            expiresAt,
            claim[1].lowercased()
        )
    }

    private static func validatedCreatedDate(_ value: String) throws -> Date {
        // `ISO8601FormatStyle` can round a value it just formatted down by one
        // millisecond when parsing it back because `Date` is binary floating
        // point. Validate the canonical wire spelling directly instead of
        // requiring a lossy format -> parse -> format byte-for-byte round trip.
        guard isCanonicalMillisecondTimestamp(value) else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        let date: Date
        do {
            date = try dateFormat.parse(value)
        } catch {
            throw FitnessPendingFITInboxError.invalidFile
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        return date
    }

    private static func isCanonicalMillisecondTimestamp(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 24,
              bytes[4] == 45,  // -
              bytes[7] == 45,  // -
              bytes[10] == 84, // T
              bytes[13] == 58, // :
              bytes[16] == 58, // :
              bytes[19] == 46, // .
              bytes[23] == 90  // Z
        else { return false }
        return bytes.indices.allSatisfy { index in
            switch index {
            case 4, 7, 10, 13, 16, 19, 23:
                true
            default:
                (48...57).contains(bytes[index])
            }
        }
    }

    private static func parsedLegacyCreatedDate(_ value: String) throws -> Date {
        let date: Date
        do {
            date = try dateFormat.parse(value)
        } catch {
            throw FitnessPendingFITInboxError.invalidFile
        }
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        return date
    }

    private static func reconciliationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .creationDateKey,
        ])
        return values?.contentModificationDate ?? values?.creationDate ?? .distantFuture
    }

    private static func claimedReconciliationPriority(
        _ url: URL,
        parent: URL,
        now: Date
    ) -> Int {
        guard isSafeDirectDirectory(url,parent: parent) else { return 3 }
        guard let claim = parseClaimName(url.lastPathComponent) else { return 3 }
        return claim.expiresAt <= now ? 0 : 1
    }

    private static func readyReconciliationPriority(_ url: URL,parent: URL) -> Int {
        guard isSafeDirectDirectory(url,parent: parent) else { return 3 }
        return isReadyDirectoryName(url.lastPathComponent) ? 1 : 3
    }

    /// Streams the App Group directory and retains only a bounded best set of
    /// exact-owned candidates. Near-miss/provider directories cannot consume the
    /// reconciliation budget or force an unbounded directory allocation.
    private static func boundedDirectDirectories(
        in directory: URL,
        limit: Int,
        context: Context,
        where isCandidate: (URL) -> Bool,
        sortedBy areInIncreasingOrder: (URL, URL) -> Bool,
        failIfTruncated: Bool = false
    ) throws -> [URL] {
        guard limit > 0 else { return [] }
        let root = directory.standardizedFileURL
        guard isSafeDirectDirectory(root, parent: root.deletingLastPathComponent()) else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        var didEncounterError = false
        guard let enumerator = context.fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .contentModificationDateKey,
                .creationDateKey,
            ],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in
                didEncounterError = true
                return false
            }
        ) else { throw FitnessPendingFITInboxError.coordinationFailed }
        var selected: [URL] = []
        while let child = enumerator.nextObject() as? URL {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == root,
                  isCandidate(candidate) else { continue }
            selected.append(candidate)
            selected.sort(by: areInIncreasingOrder)
            if selected.count > limit {
                guard !failIfTruncated else {
                    throw FitnessPendingFITInboxError.coordinationFailed
                }
                selected.removeLast()
            }
        }
        guard !didEncounterError else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        return selected
    }

    private static func isReadyDirectoryName(_ name: String) -> Bool {
        guard name.hasSuffix(itemSuffix) else { return false }
        let identifier = String(name.dropLast(itemSuffix.count))
        return UUID(uuidString: identifier) != nil
            && name == readyName(id: identifier)
    }

    private static func isSafeDirectDirectory(_ url: URL, parent: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == parent,
              let values = try? candidate.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
              ]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isTemporaryStageName(_ name: String) -> Bool {
        let prefix = ".stage-"
        guard name.hasPrefix(prefix) else { return false }
        let value = String(name.dropFirst(prefix.count))
        guard value.count == 73 else { return false }
        let separator = value.index(value.startIndex, offsetBy: 36)
        guard value[separator] == "-" else { return false }
        let first = String(value[..<separator])
        let second = String(value[value.index(after: separator)...])
        return UUID(uuidString: first) != nil && UUID(uuidString: second) != nil
    }

    private static func reservationIsLive(_ directory: URL) throws -> Bool {
        if liveReservations.contains(directory) { return true }
        let lockURL = directory.appendingPathComponent(reservationLockFilename)
        guard !(try pathIsAbsent(lockURL)) else { return false }
        let values = try lockURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return false
        }
        guard errno == EWOULDBLOCK else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    private static func validatedFilename(_ value: String, limits: Limits) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name.count <= limits.maximumFilenameCharacters,
              URL(fileURLWithPath: name).pathExtension.lowercased() == "fit",
              name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("\0") else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        return name
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var needsClose = true
        do {
            var digest = SHA256()
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                digest.update(data: data)
            }
            let result = digest.finalize().map { String(format: "%02x", $0) }.joined()
            needsClose = false
            try handle.close()
            return result
        } catch {
            let primaryError = error
            if needsClose {
                do {
                    try handle.close()
                } catch {
                    fitnessPendingFITInboxLogger.error(
                        "Failed to close a FIT file after an earlier read failure: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw primaryError
        }
    }

    private static func pathIsAbsent(_ url: URL) throws -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 { return false }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    private static func isConfirmedInvalidItemError(_ error: Error) -> Bool {
        if let inboxError = error as? FitnessPendingFITInboxError,
           case .invalidFile = inboxError {
            return true
        }
        if error is DecodingError { return true }
        if let posixError = error as? POSIXError, posixError.code == .ENOENT {
            return true
        }
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && (cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError)
    }

    private static func atomicRename(_ source: URL, _ destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func protectRecursively(_ directory: URL, context: Context) throws {
        try context.fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path
        )
        guard let enumerator = context.fileManager.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for case let child as URL in enumerator {
            try context.fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: child.path
            )
        }
    }

    // MARK: Legacy migration

    private static func legacyEntries(defaults: UserDefaults?) -> [SharedFitnessFITPayload] {
        do {
            return try decodedLegacyEntries(defaults: defaults)
        } catch {
            // Keep the undecodable legacy queue in UserDefaults so a later
            // recovery build can inspect it; never reinterpret or erase it.
            fitnessPendingFITInboxLogger.error(
                "Legacy FIT queue could not be decoded and was retained: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    private static func decodedLegacyEntries(
        defaults: UserDefaults?
    ) throws -> [SharedFitnessFITPayload] {
        guard let data = defaults?.data(forKey: queueKey) else { return [] }
        guard data.count <= maximumLegacyQueueBytes else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let entries = try JSONDecoder().decode([SharedFitnessFITPayload].self, from: data)
        guard entries.count <= maximumLegacyQueueEntries else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        return entries
    }

    private static func validateLegacyEntry(
        _ entry: SharedFitnessFITPayload,
        context: Context,
        allowMissingSource: Bool
    ) throws -> (sourceURL: URL, filename: String, createdAt: Date) {
        let legacyRoot = try validatedLegacyRoot(
            context: context,
            allowMissing: allowMissingSource
        )
        let source = URL(fileURLWithPath: entry.filePath).standardizedFileURL
        guard UUID(uuidString: entry.id) != nil,
              source.deletingLastPathComponent() == legacyRoot,
              source.pathExtension.lowercased() == "fit",
              entry.byteCount > 0,
              entry.byteCount <= context.limits.maximumFileBytes,
              entry.ownerIdentity.map(isValidIdentity) ?? true else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        let filename = try validatedFilename(entry.originalFilename, limits: context.limits)
        let createdAt = try parsedLegacyCreatedDate(entry.createdAt)
        if try pathIsAbsent(source) {
            guard allowMissingSource else {
                throw FitnessPendingFITInboxError.invalidFile
            }
        } else {
            let values = try source.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == entry.byteCount else {
                throw FitnessPendingFITInboxError.invalidFile
            }
        }
        return (source, filename, createdAt)
    }

    /// Proves the legacy parent itself is a directory entry, rather than
    /// trusting a standardized path whose parent could redirect through a
    /// symbolic link outside the App Group. A missing root is acceptable only
    /// while cleaning an already-published/missing legacy source.
    private static func validatedLegacyRoot(
        context: Context,
        allowMissing: Bool
    ) throws -> URL {
        let root = context.containerURL.appendingPathComponent(
            legacyDirectoryName,
            isDirectory: true
        ).standardizedFileURL
        var information = stat()
        guard lstat(root.path, &information) == 0 else {
            if errno == ENOENT, allowMissing { return root }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (information.st_mode & S_IFMT) == S_IFDIR else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        return root
    }

    private static func removeLegacyEntryLocked(
        _ entry: SharedFitnessFITPayload,
        context: Context
    ) throws {
        var entries = try decodedLegacyEntries(defaults: context.defaults)
        guard let index = entries.firstIndex(of: entry) else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        entries.remove(at: index)
        if entries.isEmpty {
            context.defaults?.removeObject(forKey: queueKey)
        } else {
            context.defaults?.set(try JSONEncoder().encode(entries), forKey: queueKey)
        }
    }

    private static func prepareLegacyMigrationLocked(
        id: String,
        ownerIdentity: String?,
        requiredActiveIdentity: String,
        context: Context
    ) throws -> LegacyMigrationPreparation {
        try requireActiveIdentity(requiredActiveIdentity, context: context)
        try prepareAndReconcileLocked(context: context, now: Date())
        guard let entry = try decodedLegacyEntries(defaults: context.defaults).first(where: {
            $0.id == id && $0.ownerIdentity == ownerIdentity
        }) else { return .unavailable }

        let metadata: (sourceURL: URL, filename: String, createdAt: Date)
        do {
            metadata = try validateLegacyEntry(
                entry,
                context: context,
                allowMissingSource: true
            )
        } catch where isConfirmedInvalidItemError(error) {
            return .unavailable
        }
        let durable = try ([readyDirectory(context), claimedDirectory(context)]
            .flatMap { try validItems(in: $0, context: context) })
        if let existing = durable.first(where: { $0.item.id == entry.id }) {
            guard try legacyEntry(entry, metadata: metadata, matches: existing.item) else {
                throw FitnessPendingFITInboxError.invalidFile
            }
            guard !(try pathIsAbsent(metadata.sourceURL)) else {
                try removeLegacyEntryLocked(entry, context: context)
                return .cleanedPublishedDuplicate
            }
            let durableAsset = existing.directory.appendingPathComponent(assetFilename)
            return .verifyPublishedDuplicate(LegacyPublishedDuplicateSnapshot(
                entry: entry,
                sourceURL: metadata.sourceURL,
                sourceFingerprint: try assetFingerprint(metadata.sourceURL),
                durableDirectory: existing.directory,
                durableFingerprint: try assetFingerprint(durableAsset),
                expectedSHA256: existing.item.sha256,
                boundary: try captureProducerBoundaryLocked(
                    owner: requiredActiveIdentity,
                    context: context
                )
            ))
        }
        guard !(try pathIsAbsent(metadata.sourceURL)) else { return .unavailable }
        let boundary = try captureProducerBoundaryLocked(
            owner: requiredActiveIdentity,
            context: context
        )
        return .migrate(LegacyMigrationSnapshot(
            entry: entry,
            sourceURL: metadata.sourceURL,
            filename: metadata.filename,
            createdAt: metadata.createdAt,
            boundary: boundary
        ))
    }

    private static func legacyEntry(
        _ entry: SharedFitnessFITPayload,
        metadata: (sourceURL: URL, filename: String, createdAt: Date),
        matches item: StoredItem
    ) throws -> Bool {
        let itemCreatedAt = try validatedCreatedDate(item.createdAt)
        return item.ownerIdentity == entry.ownerIdentity
            && item.originalFilename == metadata.filename
            && item.byteCount == entry.byteCount
            && itemCreatedAt == metadata.createdAt
    }

    private static func finishLegacyDuplicateVerificationLocked(
        _ snapshot: LegacyPublishedDuplicateSnapshot,
        sourceSHA256: String,
        durableSHA256: String,
        context: Context
    ) throws {
        try validateProducerBoundaryLocked(snapshot.boundary, context: context)
        guard try decodedLegacyEntries(defaults: context.defaults)
                .contains(snapshot.entry) else {
            throw FitnessPendingFITInboxError.coordinationFailed
        }
        let metadata = try validateLegacyEntry(
            snapshot.entry,
            context: context,
            allowMissingSource: false
        )
        let durable = try ([readyDirectory(context), claimedDirectory(context)]
            .flatMap { try validItems(in: $0, context: context) })
        guard let existing = durable.first(where: {
            $0.item.id == snapshot.entry.id
                && $0.directory.standardizedFileURL
                    == snapshot.durableDirectory.standardizedFileURL
        }),
              try legacyEntry(snapshot.entry, metadata: metadata, matches: existing.item),
              try assetFingerprint(metadata.sourceURL) == snapshot.sourceFingerprint,
              try assetFingerprint(
                  existing.directory.appendingPathComponent(assetFilename)
              ) == snapshot.durableFingerprint,
              existing.item.sha256 == snapshot.expectedSHA256,
              sourceSHA256 == snapshot.expectedSHA256,
              durableSHA256 == snapshot.expectedSHA256 else {
            throw FitnessPendingFITInboxError.invalidFile
        }
        try context.fileManager.removeItem(at: metadata.sourceURL)
        try removeLegacyEntryLocked(snapshot.entry, context: context)
    }

    @discardableResult
    private static func migrateLegacyEntry(
        id: String,
        ownerIdentity: String?,
        requiredActiveIdentity: String,
        context: Context
    ) throws -> Bool {
        let preparation = try withCoordination(context) {
            try prepareLegacyMigrationLocked(
                id: id,
                ownerIdentity: ownerIdentity,
                requiredActiveIdentity: requiredActiveIdentity,
                context: context
            )
        }
        switch preparation {
        case .unavailable:
            return false
        case .cleanedPublishedDuplicate:
            return true
        case .verifyPublishedDuplicate(let snapshot):
            // Both potentially large reads stay outside the global inbox lock.
            // Cheap inode/size/mtime fingerprints are rechecked while locked
            // before the legacy source is removed.
            let sourceSHA256 = try sha256(of: snapshot.sourceURL)
            let durableSHA256 = try sha256(
                of: snapshot.durableDirectory.appendingPathComponent(assetFilename)
            )
            try withCoordination(context) {
                try finishLegacyDuplicateVerificationLocked(
                    snapshot,
                    sourceSHA256: sourceSHA256,
                    durableSHA256: durableSHA256,
                    context: context
                )
            }
            return true
        case .migrate(let snapshot):
            let item = try makeStoredItem(
                id: snapshot.entry.id,
                sourceURL: snapshot.sourceURL,
                originalFilename: snapshot.filename,
                byteCount: snapshot.entry.byteCount,
                ownerIdentity: snapshot.entry.ownerIdentity,
                context: context,
                now: snapshot.createdAt
            )
            let reservation = try withCoordination(context) {
                try validateProducerBoundaryLocked(snapshot.boundary, context: context)
                guard try decodedLegacyEntries(defaults: context.defaults)
                    .contains(snapshot.entry) else {
                    throw FitnessPendingFITInboxError.coordinationFailed
                }
                _ = try validateLegacyEntry(
                    snapshot.entry,
                    context: context,
                    allowMissingSource: false
                )
                try assertCapacity(
                    addingByteCount: item.byteCount,
                    excludingLegacyEntry: snapshot.entry,
                    context: context
                )
                return try reserveStageLocked(item: item, context: context)
            }
            let staged = reservation.directory
            defer { liveReservations.remove(staged) }
            do {
                try populateReservedStage(
                    item: item,
                    sourceURL: snapshot.sourceURL,
                    directory: staged,
                    context: context
                )
                try withCoordination(context) {
                    try validateProducerBoundaryLocked(snapshot.boundary, context: context)
                    guard try decodedLegacyEntries(defaults: context.defaults)
                        .contains(snapshot.entry) else {
                        throw FitnessPendingFITInboxError.coordinationFailed
                    }
                    _ = try validateLegacyEntry(
                        snapshot.entry,
                        context: context,
                        allowMissingSource: false
                    )
                    try prepareAndReconcileLocked(
                        context: context,
                        now: Date(),
                        preservingTemporary: staged
                    )
                    try assertCapacity(
                        addingByteCount: item.byteCount,
                        excludingTemporaryDirectory: staged,
                        excludingLegacyEntry: snapshot.entry,
                        context: context
                    )
                    let destination = readyDirectory(context).appendingPathComponent(
                        readyName(id: item.id),
                        isDirectory: true
                    )
                    guard try pathIsAbsent(destination) else {
                        throw FitnessPendingFITInboxError.coordinationFailed
                    }
                    try reservation.finishBeforePublishing()
                    try atomicRename(staged, destination)
                    try context.fileManager.removeItem(at: snapshot.sourceURL)
                    try removeLegacyEntryLocked(snapshot.entry, context: context)
                }
                return true
            } catch {
                if context.fileManager.fileExists(atPath: staged.path) {
                    do {
                        try context.fileManager.removeItem(at: staged)
                    } catch {
                        fitnessPendingFITInboxLogger.error(
                            "Failed to clean an unpublished legacy FIT reservation: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                throw error
            }
        }
    }

    private static func migrateLegacyEntries(
        ownerIdentity: String?,
        specificID: String? = nil,
        requiredActiveIdentity: String,
        context: Context
    ) throws {
        let ids = try withCoordination(context) {
            try requireActiveIdentity(requiredActiveIdentity, context: context)
            return Array(try decodedLegacyEntries(defaults: context.defaults)
                .lazy
                .filter { entry in
                    entry.ownerIdentity == ownerIdentity
                        && (specificID == nil || entry.id == specificID)
                }
                .prefix(max(1, context.limits.maximumReconciliationCandidates))
                .map(\.id))
        }
        var attempted = Set<String>()
        for id in ids where attempted.insert(id).inserted {
            _ = try migrateLegacyEntry(
                id: id,
                ownerIdentity: ownerIdentity,
                requiredActiveIdentity: requiredActiveIdentity,
                context: context
            )
        }
    }

    private static func purgeOwnedLegacy(identity: String, context: Context) throws {
        let entries = try decodedLegacyEntries(defaults: context.defaults)
        let removed = entries.filter { $0.ownerIdentity == identity }
        let remaining = entries.filter { $0.ownerIdentity != identity }
        for entry in removed {
            let validated = try validateLegacyEntry(
                entry,
                context: context,
                allowMissingSource: true
            )
            let url = validated.sourceURL
            guard !(try pathIsAbsent(url)) else { continue }
            try context.fileManager.removeItem(at: url)
        }
        if remaining.isEmpty {
            context.defaults?.removeObject(forKey: queueKey)
        } else {
            context.defaults?.set(try JSONEncoder().encode(remaining), forKey: queueKey)
        }
    }
}

#if !FIT_SHARE_EXTENSION
extension FitnessPendingFITInbox {
    static func adoptAll(
        identity: String,
        repository: FitnessActivityRepository = .shared,
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) async throws -> Int {
        guard let containerURL else { return 0 }
        let context = Context(containerURL: containerURL, defaults: defaults, fileManager: fileManager)
        var adopted = 0
        var attempted = Set<String>()
        while let claim = try claimNextOwned(
            for: identity, excluding: attempted, context: context
        ) {
            attempted.insert(claim.payload.id)
            do {
                _ = try await repository.stageFIT(
                    at: URL(fileURLWithPath: claim.payload.filePath),
                    id: claim.payload.id,
                    originalFilename: claim.payload.originalFilename
                )
                try acknowledge(claim, context: context)
                adopted += 1
            } catch {
                let adoptionError = error
                do {
                    _ = try release(claim, context: context)
                } catch {
                    fitnessPendingFITInboxLogger.fault(
                        "FIT adoption failed and its claim could not be released; claimed source retained. Adoption error: \(adoptionError.localizedDescription, privacy: .public). Release error: \(error.localizedDescription, privacy: .public)"
                    )
                    throw FitnessPendingFITInboxError.claimRecoveryFailed
                }
            }
        }
        return adopted
    }

    @discardableResult
    static func adoptUnowned(
        id: String,
        identity: String,
        repository: FitnessActivityRepository = .shared,
        defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
        containerURL: URL? = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: suiteName
        ),
        fileManager: FileManager = .default
    ) async throws -> FitnessPendingFITImport {
        guard let containerURL else { throw FitnessPendingFITInboxError.containerUnavailable }
        let context = Context(containerURL: containerURL, defaults: defaults, fileManager: fileManager)
        guard let claim = try claim(id: id, for: identity, allowUnowned: true, context: context) else {
            throw FitnessPendingFITInboxError.itemNotFound
        }
        do {
            let pending = try await repository.stageFIT(
                at: URL(fileURLWithPath: claim.payload.filePath),
                id: claim.payload.id,
                originalFilename: claim.payload.originalFilename
            )
            try acknowledge(claim, context: context)
            return pending
        } catch {
            let adoptionError = error
            do {
                _ = try release(claim, context: context)
            } catch {
                fitnessPendingFITInboxLogger.fault(
                    "Unowned FIT adoption failed and its claim could not be released; claimed source retained. Adoption error: \(adoptionError.localizedDescription, privacy: .public). Release error: \(error.localizedDescription, privacy: .public)"
                )
                throw FitnessPendingFITInboxError.claimRecoveryFailed
            }
            throw adoptionError
        }
    }
}
#endif
