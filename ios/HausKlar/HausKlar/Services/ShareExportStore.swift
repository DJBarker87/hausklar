import CryptoKit
import Darwin
import Foundation
import os

/// Foundation documents delegate-free `FileManager` operations as thread-safe.
/// This wrapper is used only to move the injected/default manager into one
/// detached filesystem operation; HausKlar never assigns a delegate to it.
private struct ShareExportSendableFileManager: @unchecked Sendable {
    let value: FileManager
}

struct ShareExportOwnerLease: Hashable, Sendable {
    fileprivate let ownerHash: String
    fileprivate let generation: UInt64
}

struct ShareExportItem: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    fileprivate let ownerHash: String
    fileprivate let generation: UInt64
    fileprivate let directory: URL
}

struct ShareExportReconciliationReport: Equatable, Sendable {
    let removedCount: Int
    let inspectedCandidateCount: Int
    let candidateLimitReached: Bool
    let effectLimitReached: Bool
}

enum ShareExportStoreError: LocalizedError {
    case notActive
    case staleLease
    case invalidFile
    case fileTooLarge
    case quotaExceeded
    case cleanupFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .notActive:
            return "Sign in again before preparing a file to share."
        case .staleLease:
            return "The active account changed before the share file was ready."
        case .invalidFile:
            return "HausKlar could not verify the file prepared for sharing."
        case .fileTooLarge:
            return "That file is too large to prepare for sharing."
        case .quotaExceeded:
            return "HausKlar is still cleaning older share files. Please try again shortly."
        case .cleanupFailed(let url, let error):
            return "HausKlar could not securely clean \(url.path): \(error.localizedDescription)"
        }
    }
}

/// One protected, owner-scoped publication point for ephemeral share files.
///
/// Every item starts with one UI hold. The view that receives it must release
/// that hold when replacing the item or leaving the screen. Account transitions
/// invalidate the generation and synchronously remove the prior owner's root.
actor ShareExportStore {
    struct Limits: Equatable, Sendable {
        var maximumItemBytes = 75 * 1_024 * 1_024
        var maximumTotalBytes = 250 * 1_024 * 1_024
        var maximumItems = 24
        var maximumAge: TimeInterval = 24 * 60 * 60
        var stagingMaximumAge: TimeInterval = 60 * 60
        var maximumReconciliationCandidates = 128
        var maximumReconciliationEffects = 32
    }

    static let shared = ShareExportStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.example.hausklar",
        category: "ShareExportStore"
    )

    typealias MoveOperation = @Sendable (URL, URL) throws -> Void

    private struct Manifest: Codable {
        let version: Int
        let id: String
        let ownerHash: String
        let filename: String
        let byteCount: Int
        let createdAt: Date
    }

    private struct Record {
        let manifest: Manifest
        let directory: URL
        let file: URL
    }

    private struct Scan {
        var itemCount = 0
        var byteCount = 0
        var eligibleCount = 0
        var oldest: [Record] = []
        var inspectedCandidateCount = 0
        var candidateLimitReached = false
    }

    private static let manifestFilename = "manifest.json"
    private static let manifestVersion = 1
    private static let maximumManifestBytes = 16 * 1_024
    private static let copyChunkBytes = 1_024 * 1_024

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let limits: Limits
    private let moveOperation: MoveOperation?
    private let ioProbe: (@Sendable () -> Void)?
    private var generation: UInt64 = 0
    private var activeLease: ShareExportOwnerLease?
    private var holds: [String: Int] = [:]
    private var reservations: [UUID: Int] = [:]

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        limits: Limits = Limits(),
        moveOperation: MoveOperation? = nil,
        ioProbe: (@Sendable () -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.rootDirectory =
            rootDirectory
            ?? fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("HausKlarShareExports", isDirectory: true)
        self.limits = limits
        self.moveOperation = moveOperation
        self.ioProbe = ioProbe
    }

    @discardableResult
    func activate(identity: String, now: Date = Date()) throws -> ShareExportOwnerLease {
        let ownerHash = Self.identityHash(identity)
        if let activeLease, activeLease.ownerHash == ownerHash { return activeLease }
        if let previous = activeLease {
            try removeOwnerDirectory(ownerHash: previous.ownerHash)
        }
        generation &+= 1
        let lease = ShareExportOwnerLease(ownerHash: ownerHash, generation: generation)
        activeLease = lease
        holds.removeAll(keepingCapacity: true)
        reservations.removeAll(keepingCapacity: true)
        do {
            try prepareOwnerDirectory(for: lease)
            try purgeInactiveOwnerDirectories(keeping: ownerHash)
            _ = try reconcile(lease: lease, now: now)
            return lease
        } catch let activationError {
            var cleanupError: Error?
            do {
                try removeOwnerDirectory(ownerHash: ownerHash)
            } catch {
                cleanupError = error
            }
            activeLease = nil
            generation &+= 1
            if let cleanupError {
                throw ShareExportStoreError.cleanupFailed(
                    ownerDirectory(for: ownerHash),
                    cleanupError
                )
            }
            throw activationError
        }
    }

    func currentLease() throws -> ShareExportOwnerLease {
        guard let activeLease else { throw ShareExportStoreError.notActive }
        return activeLease
    }

    /// Used by logout/account replacement. This method returns only after the
    /// exact HausKlar export root has been removed or a blocking error is known.
    func securePurgeAll() throws {
        activeLease = nil
        generation &+= 1
        holds.removeAll(keepingCapacity: false)
        reservations.removeAll(keepingCapacity: false)
        let root = rootDirectory.standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else { return }
        let values = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ShareExportStoreError.invalidFile
        }
        try fileManager.removeItem(at: root)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw ShareExportStoreError.cleanupFailed(root, CocoaError(.fileWriteUnknown))
        }
    }

    func publishData(
        _ data: Data,
        filename: String,
        lease: ShareExportOwnerLease
    ) async throws -> ShareExportItem {
        guard !data.isEmpty else { throw ShareExportStoreError.invalidFile }
        guard data.count <= limits.maximumItemBytes else {
            throw ShareExportStoreError.fileTooLarge
        }
        return try await publishGeneratedFile(
            filename: filename,
            maximumBytes: data.count,
            lease: lease
        ) { destination in
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
        }
    }

    func publishGeneratedFile(
        filename: String,
        maximumBytes: Int,
        lease: ShareExportOwnerLease,
        writer: @escaping @Sendable (URL) throws -> Void
    ) async throws -> ShareExportItem {
        try validate(lease)
        guard maximumBytes > 0, maximumBytes <= limits.maximumItemBytes else {
            throw ShareExportStoreError.fileTooLarge
        }
        let reservation = try reserve(maximumBytes: maximumBytes, lease: lease)
        defer { reservations[reservation] = nil }
        let publication = try makeStagingPublication(filename: filename, lease: lease)
        do {
            let probe = ioProbe
            let task = Task.detached(priority: .userInitiated) {
                probe?()
                try Task.checkCancellation()
                try writer(publication.file)
                try Task.checkCancellation()
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try validate(lease)
            let byteCount = try validatedFileByteCount(
                publication.file,
                maximumBytes: maximumBytes
            )
            let item = try finalize(
                publication,
                byteCount: byteCount,
                lease: lease
            )
            try Task.checkCancellation()
            holds[item.id] = 1
            return item
        } catch {
            try cleanupPublication(
                staging: publication.directory,
                published: publication.destinationDirectory
            )
            throw error
        }
    }

    /// Adopts an API client's downloaded temporary file. A same-volume rename
    /// is preferred; EXDEV alone triggers a capped streaming copy fallback.
    func adoptDownloadedFile(
        _ sourceURL: URL,
        filename: String,
        expectedByteCount: Int? = nil,
        maximumBytes: Int,
        lease: ShareExportOwnerLease
    ) async throws -> ShareExportItem {
        try validate(lease)
        guard maximumBytes > 0, maximumBytes <= limits.maximumItemBytes else {
            throw ShareExportStoreError.fileTooLarge
        }
        let sourceByteCount = try await observeSource(
            sourceURL,
            expectedByteCount: expectedByteCount,
            maximumBytes: maximumBytes
        )
        let reservation = try reserve(maximumBytes: sourceByteCount, lease: lease)
        defer { reservations[reservation] = nil }
        let publication = try makeStagingPublication(filename: filename, lease: lease)
        do {
            let mover = moveOperation
            let manager = ShareExportSendableFileManager(value: fileManager)
            let probe = ioProbe
            let task = Task.detached(priority: .userInitiated) {
                probe?()
                try Self.adoptOnDisk(
                    sourceURL,
                    destination: publication.file,
                    expectedByteCount: sourceByteCount,
                    maximumBytes: maximumBytes,
                    fileManager: manager.value,
                    moveOperation: mover
                )
            }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try validate(lease)
            let byteCount = try validatedFileByteCount(
                publication.file,
                maximumBytes: maximumBytes
            )
            guard byteCount == sourceByteCount else {
                throw ShareExportStoreError.invalidFile
            }
            let item = try finalize(
                publication,
                byteCount: byteCount,
                lease: lease
            )
            try Task.checkCancellation()
            holds[item.id] = 1
            return item
        } catch {
            try cleanupPublication(
                staging: publication.directory,
                published: publication.destinationDirectory
            )
            throw error
        }
    }

    func retain(_ item: ShareExportItem) throws {
        try validate(item)
        holds[item.id, default: 0] += 1
    }

    func release(_ item: ShareExportItem) throws {
        guard item.generation == activeLease?.generation,
            item.ownerHash == activeLease?.ownerHash
        else { return }
        let remaining = max(0, (holds[item.id] ?? 1) - 1)
        if remaining > 0 {
            holds[item.id] = remaining
            return
        }
        holds[item.id] = nil
        let directory = try validatedItemDirectory(item)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Ends a UI ownership hold without turning cleanup into a hidden failure.
    /// A failed removal is safe to retry: the hold is already retired and the
    /// next bounded reconciliation/publication will inspect the exact artifact.
    func releaseAfterUse(_ item: ShareExportItem) {
        do {
            try release(item)
        } catch {
            Self.logger.error(
                "Share export release failed for \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public). Reconciliation: the next owner activation or export publication retries exact unheld artifacts."
            )
        }
    }

    @discardableResult
    func reconcile(
        lease: ShareExportOwnerLease,
        now: Date = Date()
    ) throws -> ShareExportReconciliationReport {
        try validate(lease)
        try prepareOwnerDirectory(for: lease)
        let ownerDirectory = self.ownerDirectory(for: lease.ownerHash)
        let candidateLimit = max(0, limits.maximumReconciliationCandidates)
        let effectLimit = max(0, limits.maximumReconciliationEffects)
        var stageCandidates: [(date: Date, url: URL)] = []
        var stageEligibleCount = 0
        var stageInspectedCount = 0
        let stageCutoff = now.addingTimeInterval(-max(0, limits.stagingMaximumAge))

        let stageCandidateLimitReached = try forEachImmediateEntry(
            in: ownerDirectory,
            maximumEntries: candidateLimit
        ) { entry in
            stageInspectedCount += 1
            guard Self.stageID(entry.lastPathComponent) != nil else { return }
            let values = try entry.resourceValues(forKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                values.isSymbolicLink != true,
                let date = values.contentModificationDate ?? values.creationDate,
                date <= stageCutoff
            else { return }
            stageEligibleCount += 1
            Self.insertOldest(
                (date, entry),
                into: &stageCandidates,
                limit: candidateLimit
            )
        }

        var removedCount = 0
        for candidate in stageCandidates.prefix(effectLimit) {
            try fileManager.removeItem(at: candidate.url)
            removedCount += 1
        }

        var scan = try scanRecords(
            ownerHash: lease.ownerHash,
            candidateLimit: candidateLimit
        )
        let ageCutoff = now.addingTimeInterval(-max(0, limits.maximumAge))
        for record in scan.oldest {
            guard removedCount < effectLimit else { break }
            let overQuota =
                scan.itemCount > max(1, limits.maximumItems)
                || scan.byteCount > max(1, limits.maximumTotalBytes)
            let aged = record.manifest.createdAt <= ageCutoff
            guard aged || overQuota else { continue }
            try fileManager.removeItem(at: record.directory)
            scan.itemCount -= 1
            scan.byteCount -= record.manifest.byteCount
            removedCount += 1
        }

        let stillOverQuota =
            scan.itemCount > max(1, limits.maximumItems)
            || scan.byteCount > max(1, limits.maximumTotalBytes)
        return ShareExportReconciliationReport(
            removedCount: removedCount,
            inspectedCandidateCount: max(
                stageInspectedCount,
                scan.inspectedCandidateCount
            ),
            candidateLimitReached: stageCandidateLimitReached
                || scan.candidateLimitReached,
            effectLimitReached: stillOverQuota
                || stageEligibleCount + scan.eligibleCount > effectLimit
        )
    }

    // MARK: - Publication internals

    private struct Publication {
        let id: String
        let filename: String
        let directory: URL
        let file: URL
        let destinationDirectory: URL
    }

    private func reserve(
        maximumBytes: Int,
        lease: ShareExportOwnerLease
    ) throws -> UUID {
        try validate(lease)
        _ = try reconcile(lease: lease)
        let scan = try scanRecords(
            ownerHash: lease.ownerHash,
            candidateLimit: limits.maximumReconciliationCandidates
        )
        guard !scan.candidateLimitReached else {
            throw ShareExportStoreError.quotaExceeded
        }
        let reservedBytes = reservations.values.reduce(0, +)
        guard scan.itemCount + reservations.count + 1 <= max(1, limits.maximumItems),
            scan.byteCount + reservedBytes + maximumBytes <= max(1, limits.maximumTotalBytes)
        else {
            throw ShareExportStoreError.quotaExceeded
        }
        let reservation = UUID()
        reservations[reservation] = maximumBytes
        return reservation
    }

    private func makeStagingPublication(
        filename: String,
        lease: ShareExportOwnerLease
    ) throws -> Publication {
        try validate(lease)
        let id = UUID().uuidString.lowercased()
        let ownerDirectory = self.ownerDirectory(for: lease.ownerHash)
        let staging = ownerDirectory.appendingPathComponent(".stage-\(id)", isDirectory: true)
        let destination = ownerDirectory.appendingPathComponent("\(id).export", isDirectory: true)
        try LocalFileProtection.prepareDirectory(staging, fileManager: fileManager)
        let safeFilename = Self.safeFilename(filename)
        return Publication(
            id: id,
            filename: safeFilename,
            directory: staging,
            file: staging.appendingPathComponent(safeFilename),
            destinationDirectory: destination
        )
    }

    private func finalize(
        _ publication: Publication,
        byteCount: Int,
        lease: ShareExportOwnerLease
    ) throws -> ShareExportItem {
        try validate(lease)
        try LocalFileProtection.protectItem(at: publication.file, fileManager: fileManager)
        let manifest = Manifest(
            version: Self.manifestVersion,
            id: publication.id,
            ownerHash: lease.ownerHash,
            filename: publication.filename,
            byteCount: byteCount,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestURL = publication.directory.appendingPathComponent(Self.manifestFilename)
        try encoder.encode(manifest).write(
            to: manifestURL,
            options: [.atomic, .completeFileProtection]
        )
        try LocalFileProtection.protectItem(at: manifestURL, fileManager: fileManager)
        try fileManager.moveItem(
            at: publication.directory,
            to: publication.destinationDirectory
        )
        let record = try verifiedRecord(
            in: publication.destinationDirectory,
            ownerHash: lease.ownerHash
        )
        return ShareExportItem(
            id: publication.id,
            url: record.file,
            ownerHash: lease.ownerHash,
            generation: lease.generation,
            directory: record.directory
        )
    }

    private func cleanupPublication(staging: URL, published: URL?) throws {
        for directory in [staging, published].compactMap({ $0 })
        where fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
            } catch {
                throw ShareExportStoreError.cleanupFailed(directory, error)
            }
        }
    }

    private func observeSource(
        _ sourceURL: URL,
        expectedByteCount: Int?,
        maximumBytes: Int
    ) async throws -> Int {
        let probe = ioProbe
        let task = Task.detached(priority: .userInitiated) {
            probe?()
            try Task.checkCancellation()
            let values = try sourceURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let byteCount = values.fileSize,
                byteCount > 0
            else {
                throw ShareExportStoreError.invalidFile
            }
            guard byteCount <= maximumBytes else {
                throw ShareExportStoreError.fileTooLarge
            }
            if let expectedByteCount, expectedByteCount != byteCount {
                throw ShareExportStoreError.invalidFile
            }
            return byteCount
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func adoptOnDisk(
        _ sourceURL: URL,
        destination: URL,
        expectedByteCount: Int,
        maximumBytes: Int,
        fileManager: FileManager,
        moveOperation: MoveOperation?
    ) throws {
        try Task.checkCancellation()
        do {
            if let moveOperation {
                try moveOperation(sourceURL, destination)
            } else {
                try fileManager.moveItem(at: sourceURL, to: destination)
            }
        } catch {
            guard isCrossDeviceError(error) else { throw error }
            try copyBounded(
                sourceURL,
                destination: destination,
                expectedByteCount: expectedByteCount,
                maximumBytes: maximumBytes,
                fileManager: fileManager
            )
            let finalSource = try sourceURL.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard finalSource.isRegularFile == true,
                finalSource.isSymbolicLink != true,
                finalSource.fileSize == expectedByteCount
            else {
                throw ShareExportStoreError.invalidFile
            }
            try fileManager.removeItem(at: sourceURL)
        }
        try Task.checkCancellation()
        let destinationValues = try destination.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard destinationValues.isRegularFile == true,
            destinationValues.isSymbolicLink != true,
            destinationValues.fileSize == expectedByteCount
        else {
            throw ShareExportStoreError.invalidFile
        }
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
    }

    nonisolated private static func copyBounded(
        _ source: URL,
        destination: URL,
        expectedByteCount: Int,
        maximumBytes: Int,
        fileManager: FileManager
    ) throws {
        guard
            fileManager.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.protectionKey: LocalFileProtection.sensitive]
            )
        else {
            throw ShareExportStoreError.invalidFile
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        do {
            var copied = 0
            while true {
                try Task.checkCancellation()
                let remaining = maximumBytes + 1 - copied
                guard remaining > 0 else { throw ShareExportStoreError.fileTooLarge }
                let chunk = try input.read(upToCount: min(copyChunkBytes, remaining)) ?? Data()
                if chunk.isEmpty { break }
                copied += chunk.count
                guard copied <= maximumBytes else { throw ShareExportStoreError.fileTooLarge }
                try output.write(contentsOf: chunk)
            }
            guard copied == expectedByteCount else { throw ShareExportStoreError.invalidFile }
            try output.synchronize()
            try output.close()
            try input.close()
        } catch let copyError {
            var cleanupError: Error?
            do {
                try output.close()
            } catch {
                cleanupError = error
            }
            do {
                try input.close()
            } catch {
                if cleanupError == nil { cleanupError = error }
            }
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
            } catch {
                if cleanupError == nil { cleanupError = error }
            }
            if let cleanupError {
                // The caller's publication cleanup retries the UUID-owned stage;
                // surfacing this error prevents a partial adoption from passing.
                throw ShareExportStoreError.cleanupFailed(destination, cleanupError)
            }
            throw copyError
        }
    }

    nonisolated private static func isCrossDeviceError(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain, value.code == Int(EXDEV) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
            return isCrossDeviceError(underlying)
        }
        return false
    }

    // MARK: - Reconciliation internals

    private func scanRecords(ownerHash: String, candidateLimit: Int) throws -> Scan {
        let ownerDirectory = self.ownerDirectory(for: ownerHash)
        var scan = Scan()
        scan.candidateLimitReached = try forEachImmediateEntry(
            in: ownerDirectory,
            maximumEntries: max(0, candidateLimit)
        ) { entry in
            scan.inspectedCandidateCount += 1
            guard Self.itemID(entry.lastPathComponent) != nil else { return }
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return }
            let record: Record
            do {
                record = try verifiedRecord(in: entry, ownerHash: ownerHash)
            } catch {
                return
            }
            scan.itemCount += 1
            scan.byteCount += record.manifest.byteCount
            guard holds[record.manifest.id] == nil else { return }
            scan.eligibleCount += 1
            Self.insertOldestRecord(
                record,
                into: &scan.oldest,
                limit: max(0, candidateLimit)
            )
        }
        return scan
    }

    private func verifiedRecord(in directory: URL, ownerHash: String) throws -> Record {
        let directory = directory.standardizedFileURL
        guard directory.deletingLastPathComponent() == self.ownerDirectory(for: ownerHash),
            let id = Self.itemID(directory.lastPathComponent)
        else {
            throw ShareExportStoreError.invalidFile
        }
        let values = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ShareExportStoreError.invalidFile
        }
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename)
        let manifestValues = try manifestURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard manifestValues.isRegularFile == true,
            manifestValues.isSymbolicLink != true,
            let manifestBytes = manifestValues.fileSize,
            manifestBytes > 0,
            manifestBytes <= Self.maximumManifestBytes
        else {
            throw ShareExportStoreError.invalidFile
        }
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        )
        guard manifest.version == Self.manifestVersion,
            manifest.id == id,
            manifest.ownerHash == ownerHash,
            manifest.filename == Self.safeFilename(manifest.filename)
        else {
            throw ShareExportStoreError.invalidFile
        }
        let file = directory.appendingPathComponent(manifest.filename).standardizedFileURL
        guard file.deletingLastPathComponent() == directory else {
            throw ShareExportStoreError.invalidFile
        }
        let fileValues = try file.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard fileValues.isRegularFile == true,
            fileValues.isSymbolicLink != true,
            fileValues.fileSize == manifest.byteCount,
            try hasExactChildren(directory, names: [manifest.filename, Self.manifestFilename])
        else {
            throw ShareExportStoreError.invalidFile
        }
        return Record(manifest: manifest, directory: directory, file: file)
    }

    private func hasExactChildren(_ directory: URL, names: Set<String>) throws -> Bool {
        var found = Set<String>()
        let limitReached = try forEachImmediateEntry(
            in: directory,
            maximumEntries: names.count + 1
        ) { entry in
            guard names.contains(entry.lastPathComponent),
                found.insert(entry.lastPathComponent).inserted
            else {
                throw ShareExportStoreError.invalidFile
            }
        }
        return !limitReached && found == names
    }

    private func validatedFileByteCount(_ url: URL, maximumBytes: Int) throws -> Int {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let byteCount = values.fileSize,
            byteCount > 0
        else {
            throw ShareExportStoreError.invalidFile
        }
        guard byteCount <= maximumBytes, byteCount <= limits.maximumItemBytes else {
            throw ShareExportStoreError.fileTooLarge
        }
        return byteCount
    }

    @discardableResult
    private func forEachImmediateEntry(
        in directory: URL,
        maximumEntries: Int? = nil,
        _ body: (URL) throws -> Void
    ) throws -> Bool {
        let directory = directory.standardizedFileURL
        let values = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ShareExportStoreError.invalidFile
        }
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else {
            throw ShareExportStoreError.invalidFile
        }
        var inspectedCount = 0
        while let next = enumerator.nextObject() {
            guard let candidate = next as? URL else { continue }
            let entry = candidate.standardizedFileURL
            guard entry.deletingLastPathComponent() == directory else { continue }
            if let maximumEntries, inspectedCount >= max(0, maximumEntries) {
                return true
            }
            inspectedCount += 1
            try body(entry)
        }
        if let enumerationError { throw enumerationError }
        return false
    }

    private func prepareOwnerDirectory(for lease: ShareExportOwnerLease) throws {
        try validate(lease)
        try LocalFileProtection.prepareDirectory(rootDirectory, fileManager: fileManager)
        try LocalFileProtection.prepareDirectory(
            ownerDirectory(for: lease.ownerHash),
            fileManager: fileManager
        )
    }

    private func removeOwnerDirectory(ownerHash: String) throws {
        let directory = ownerDirectory(for: ownerHash)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        guard
            directory.standardizedFileURL.deletingLastPathComponent()
                == rootDirectory.standardizedFileURL,
            Self.ownerHash(directory.lastPathComponent) == ownerHash
        else {
            throw ShareExportStoreError.invalidFile
        }
        try fileManager.removeItem(at: directory)
    }

    /// A process restart has no in-memory previous lease. Remove every other
    /// exact owner namespace before exposing the current one; near misses are
    /// never treated as HausKlar-owned. `removeItem` unlinks a matching symlink
    /// itself and does not traverse its destination.
    private func purgeInactiveOwnerDirectories(keeping ownerHash: String) throws {
        let root = rootDirectory.standardizedFileURL
        let limitReached = try forEachImmediateEntry(
            in: root,
            maximumEntries: max(1, limits.maximumReconciliationCandidates) + 1
        ) { entry in
            guard let candidateHash = Self.ownerHash(entry.lastPathComponent),
                candidateHash != ownerHash,
                entry.standardizedFileURL.deletingLastPathComponent() == root
            else { return }
            try fileManager.removeItem(at: entry)
        }
        guard !limitReached else { throw ShareExportStoreError.quotaExceeded }
    }

    private func validate(_ lease: ShareExportOwnerLease) throws {
        guard let activeLease else { throw ShareExportStoreError.notActive }
        guard activeLease == lease else { throw ShareExportStoreError.staleLease }
    }

    private func validate(_ item: ShareExportItem) throws {
        guard item.ownerHash == activeLease?.ownerHash,
            item.generation == activeLease?.generation
        else {
            throw ShareExportStoreError.staleLease
        }
        _ = try verifiedRecord(in: item.directory, ownerHash: item.ownerHash)
    }

    private func validatedItemDirectory(_ item: ShareExportItem) throws -> URL {
        guard
            item.directory
                == ownerDirectory(for: item.ownerHash)
                .appendingPathComponent("\(item.id).export", isDirectory: true)
                .standardizedFileURL,
            Self.isCanonicalLowercaseUUID(item.id)
        else {
            throw ShareExportStoreError.invalidFile
        }
        return item.directory
    }

    private func ownerDirectory(for ownerHash: String) -> URL {
        rootDirectory.standardizedFileURL.appendingPathComponent(
            "owner-\(ownerHash)",
            isDirectory: true
        )
    }

    nonisolated private static func identityHash(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func stageID(_ value: String) -> String? {
        let prefix = ".stage-"
        guard value.hasPrefix(prefix) else { return nil }
        let id = String(value.dropFirst(prefix.count))
        return isCanonicalLowercaseUUID(id) ? id : nil
    }

    nonisolated private static func itemID(_ value: String) -> String? {
        let suffix = ".export"
        guard value.hasSuffix(suffix) else { return nil }
        let id = String(value.dropLast(suffix.count))
        return isCanonicalLowercaseUUID(id) ? id : nil
    }

    nonisolated private static func ownerHash(_ value: String) -> String? {
        let prefix = "owner-"
        guard value.hasPrefix(prefix) else { return nil }
        let hash = String(value.dropFirst(prefix.count))
        guard hash.count == 64,
            hash == hash.lowercased(),
            hash.unicodeScalars.allSatisfy({
                (48...57).contains($0.value) || (97...102).contains($0.value)
            })
        else { return nil }
        return hash
    }

    nonisolated private static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
        value.count == 36
            && value == value.lowercased()
            && UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    nonisolated private static func safeFilename(_ value: String) -> String {
        let candidate = (value as NSString).lastPathComponent
        let invalid = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        guard !candidate.isEmpty,
            candidate != ".",
            candidate != "..",
            !candidate.hasPrefix("."),
            candidate.caseInsensitiveCompare(manifestFilename) != .orderedSame,
            candidate.utf8.count <= 180,
            candidate.rangeOfCharacter(from: invalid) == nil
        else {
            return "HausKlar export"
        }
        return candidate
    }

    nonisolated private static func insertOldest(
        _ value: (date: Date, url: URL),
        into values: inout [(date: Date, url: URL)],
        limit: Int
    ) {
        guard limit > 0 else { return }
        values.append(value)
        values.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }
        if values.count > limit { values.removeLast() }
    }

    nonisolated private static func insertOldestRecord(
        _ record: Record,
        into values: inout [Record],
        limit: Int
    ) {
        guard limit > 0 else { return }
        values.append(record)
        values.sort {
            if $0.manifest.createdAt != $1.manifest.createdAt {
                return $0.manifest.createdAt < $1.manifest.createdAt
            }
            return $0.directory.lastPathComponent < $1.directory.lastPathComponent
        }
        if values.count > limit { values.removeLast() }
    }
}
