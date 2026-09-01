import CryptoKit
import Darwin
import Foundation

enum LocalStoreRecovery {
    static let recoveryFlag = "didRecoverLocalStore"

    static let manifestFilename = "archive-manifest-v1.json"
    static let retainedArchiveCount = 3

    struct ArchiveManifest: Codable, Equatable {
        let version: Int
        let originalStoreBasename: String
        let createdAt: Date
        let members: [ArchiveMember]
    }

    struct ArchiveMember: Codable, Equatable {
        let filename: String
        let byteCount: UInt64
        let sha256: String
    }

    enum ArchiveStep: Equatable {
        case beforeCopy(String)
        case beforeProtection(String)
        case beforePublish
        case beforeSourceRemoval(String)
    }

    enum ArchiveError: LocalizedError {
        case invalidPath(String)
        case unsupportedSource(String)
        case sourceTooLarge(String)
        case sourceChanged(String)
        case cannotCreateFile(String)
        case verificationFailed(String)
        case handleCleanupFailed(operation: Error, cleanup: [Error])
        case stagingCleanupFailed(stagingURL: URL, underlying: Error)
        case sourceCleanupFailed(archiveURL: URL, remaining: [String])

        var errorDescription: String? {
            switch self {
            case .invalidPath(let path):
                return "Unsafe recovery path: \(path)"
            case .unsupportedSource(let path):
                return "Recovery source is not a regular file: \(path)"
            case .sourceTooLarge(let path):
                return "Recovery source exceeds the archive safety limit: \(path)"
            case .sourceChanged(let path):
                return "Recovery source changed while it was being archived: \(path)"
            case .cannotCreateFile(let path):
                return "Could not create recovery file: \(path)"
            case .verificationFailed(let path):
                return "Recovery copy failed verification: \(path)"
            case .handleCleanupFailed(let operation, let cleanup):
                return "Recovery I/O failed (\(operation.localizedDescription)) and handle cleanup also failed: \(cleanup.map(\.localizedDescription).joined(separator: ", "))"
            case .stagingCleanupFailed(let stagingURL, let underlying):
                return "Could not clean recovery staging at \(stagingURL.path): \(underlying.localizedDescription)"
            case .sourceCleanupFailed(let archiveURL, let remaining):
                return
                    "The verified archive is safe at \(archiveURL.path), but source cleanup is incomplete: \(remaining.joined(separator: ", "))"
            }
        }
    }

    private struct SourceObservation {
        let byteCount: UInt64
        let fileNumber: UInt64?
        let modifiedAt: Date?
    }

    private static let archiveVersion = 1
    private static let copyChunkByteCount = 1_024 * 1_024
    private static let maximumMemberByteCount: UInt64 = 8 * 1_024 * 1_024 * 1_024
    private static let maximumArchiveByteCount: UInt64 = 12 * 1_024 * 1_024 * 1_024
    private static let sourceSuffixes = ["", "-wal", "-shm"]

    static func defaultRecoveryRoot(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("HausKlar-Recovery", isDirectory: true)
    }

    static func archiveStore(
        at storeURL: URL,
        recoveryRoot: URL? = nil,
        fileManager: FileManager = .default,
        failureInjector: ((ArchiveStep) throws -> Void)? = nil
    ) throws -> URL {
        let store = try validatedStoreURL(storeURL)
        let sources = try validatedSources(for: store, fileManager: fileManager)
        let root = try validatedRecoveryRoot(
            recoveryRoot ?? defaultRecoveryRoot(fileManager: fileManager),
            fileManager: fileManager
        )
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        try validateExistingDirectory(root, fileManager: fileManager)
        try removeInterruptedStagingDirectories(in: root, fileManager: fileManager)

        let identifier = UUID().uuidString
        let staging = try childURL(
            named: ".staging-\(identifier)",
            in: root,
            isDirectory: true
        )
        let destination = try childURL(named: identifier, in: root, isDirectory: true)
        var didPublish = false
        do {
            try LocalFileProtection.prepareDirectory(staging, fileManager: fileManager)
            try validateExistingDirectory(staging, fileManager: fileManager)
            var members: [ArchiveMember] = []
            var archiveByteCount: UInt64 = 0
            for source in sources {
                try failureInjector?(.beforeCopy(source.lastPathComponent))
                let destinationFile = try childURL(
                    named: source.lastPathComponent,
                    in: staging,
                    isDirectory: false
                )
                let member = try copyAndVerify(
                    source: source,
                    destination: destinationFile,
                    fileManager: fileManager,
                    beforeProtection: {
                        try failureInjector?(.beforeProtection(source.lastPathComponent))
                    }
                )
                let (newTotal, overflow) = archiveByteCount.addingReportingOverflow(member.byteCount)
                guard !overflow, newTotal <= maximumArchiveByteCount else {
                    throw ArchiveError.sourceTooLarge(source.path)
                }
                archiveByteCount = newTotal
                members.append(member)
            }

            let manifest = ArchiveManifest(
                version: archiveVersion,
                originalStoreBasename: store.lastPathComponent,
                createdAt: Date(),
                members: members
            )
            try writeAndVerifyManifest(
                manifest,
                in: staging,
                fileManager: fileManager
            )
            try synchronizeDirectory(staging)

            try failureInjector?(.beforePublish)
            try fileManager.moveItem(at: staging, to: destination)
            didPublish = true
            try synchronizeDirectory(root)

            // Rotation happens before touching the originals. If it cannot be
            // completed, this new verified archive remains published and every
            // source member remains in place for a later recovery attempt.
            try rotateArchives(
                in: root,
                retaining: retainedArchiveCount,
                preserving: destination,
                fileManager: fileManager
            )

            // A source that changed after publication must not be removed. The
            // archive is still useful forensic evidence, while the live bytes
            // remain available for a subsequent recovery attempt.
            do {
                for (source, member) in zip(sources, members) {
                    let observed = try digestAndCount(source, fileManager: fileManager)
                    guard observed.byteCount == member.byteCount,
                        observed.sha256 == member.sha256
                    else {
                        throw ArchiveError.verificationFailed(source.path)
                    }
                }
            } catch {
                throw ArchiveError.sourceCleanupFailed(
                    archiveURL: destination,
                    remaining: sources.map(\.lastPathComponent)
                )
            }

            var cleanupFailed = false
            for source in sources {
                do {
                    try failureInjector?(.beforeSourceRemoval(source.lastPathComponent))
                    try fileManager.removeItem(at: source)
                } catch {
                    cleanupFailed = true
                }
            }
            var remaining: [String]
            do {
                remaining = []
                for source in sources {
                    if try itemType(at: source, fileManager: fileManager) != nil {
                        remaining.append(source.lastPathComponent)
                    }
                }
            } catch {
                remaining = sources.map(\.lastPathComponent)
                cleanupFailed = true
            }
            if cleanupFailed || !remaining.isEmpty {
                throw ArchiveError.sourceCleanupFailed(
                    archiveURL: destination,
                    remaining: remaining
                )
            }
            try synchronizeDirectory(store.deletingLastPathComponent())
            return destination
        } catch {
            guard !didPublish else { throw error }
            do {
                if try itemType(at: staging, fileManager: fileManager) != nil {
                    try fileManager.removeItem(at: staging)
                    try synchronizeDirectory(root)
                }
            } catch {
                throw ArchiveError.stagingCleanupFailed(
                    stagingURL: staging,
                    underlying: error
                )
            }
            throw error
        }
    }

    static func purgeArchives(
        recoveryRoot: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let root = try validatedRecoveryRoot(
            recoveryRoot ?? defaultRecoveryRoot(fileManager: fileManager),
            fileManager: fileManager
        )
        guard try itemType(at: root, fileManager: fileManager) != nil else { return }
        try fileManager.removeItem(at: root)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func validatedStoreURL(_ url: URL) throws -> URL {
        guard url.isFileURL,
            url.path.hasPrefix("/"),
            url.standardizedFileURL.path == url.path
        else {
            throw ArchiveError.invalidPath(url.path)
        }
        let store = url.standardizedFileURL
        let basename = store.lastPathComponent
        guard !basename.isEmpty,
            basename != ".",
            basename != "..",
            !basename.contains("/"),
            store.deletingLastPathComponent() != store
        else {
            throw ArchiveError.invalidPath(url.path)
        }
        return store
    }

    private static func validatedRecoveryRoot(
        _ url: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard url.isFileURL,
            url.path.hasPrefix("/"),
            url.standardizedFileURL.path == url.path
        else {
            throw ArchiveError.invalidPath(url.path)
        }
        let root = url.standardizedFileURL
        guard root.path != "/", root.deletingLastPathComponent() != root else {
            throw ArchiveError.invalidPath(root.path)
        }
        if let type = try itemType(at: root, fileManager: fileManager), type != .typeDirectory {
            throw ArchiveError.invalidPath(root.path)
        }
        return root
    }

    private static func validatedSources(
        for store: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        let parent = store.deletingLastPathComponent()
        var sources: [URL] = []
        var totalBytes: UInt64 = 0
        for suffix in sourceSuffixes {
            let source = try childURL(
                named: store.lastPathComponent + suffix,
                in: parent,
                isDirectory: false
            )
            guard let type = try itemType(at: source, fileManager: fileManager) else { continue }
            guard type == .typeRegular else {
                throw ArchiveError.unsupportedSource(source.path)
            }
            let observation = try observeSource(source, fileManager: fileManager)
            guard observation.byteCount <= maximumMemberByteCount else {
                throw ArchiveError.sourceTooLarge(source.path)
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(observation.byteCount)
            guard !overflow, newTotal <= maximumArchiveByteCount else {
                throw ArchiveError.sourceTooLarge(source.path)
            }
            totalBytes = newTotal
            sources.append(source)
        }
        return sources
    }

    private static func childURL(
        named name: String,
        in parent: URL,
        isDirectory: Bool
    ) throws -> URL {
        guard !name.isEmpty,
            name != ".",
            name != "..",
            !name.contains("/"),
            !name.contains(":")
        else {
            throw ArchiveError.invalidPath(name)
        }
        let child = parent.appendingPathComponent(name, isDirectory: isDirectory).standardizedFileURL
        guard child.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL else {
            throw ArchiveError.invalidPath(child.path)
        }
        return child
    }

    private static func itemType(
        at url: URL,
        fileManager: FileManager
    ) throws -> FileAttributeType? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType
        } catch let error as CocoaError
            where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        {
            return nil
        }
    }

    private static func validateExistingDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        guard try itemType(at: directory, fileManager: fileManager) == .typeDirectory else {
            throw ArchiveError.invalidPath(directory.path)
        }
    }

    private static func observeSource(
        _ source: URL,
        fileManager: FileManager
    ) throws -> SourceObservation {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ArchiveError.unsupportedSource(source.path)
        }
        guard let size = attributes[.size] as? NSNumber else {
            throw ArchiveError.unsupportedSource(source.path)
        }
        return SourceObservation(
            byteCount: size.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }

    private static func copyAndVerify(
        source: URL,
        destination: URL,
        fileManager: FileManager,
        beforeProtection: () throws -> Void
    ) throws -> ArchiveMember {
        let before = try observeSource(source, fileManager: fileManager)
        guard before.byteCount <= maximumMemberByteCount else {
            throw ArchiveError.sourceTooLarge(source.path)
        }
        guard try itemType(at: destination, fileManager: fileManager) == nil,
            fileManager.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.protectionKey: LocalFileProtection.sensitive]
            )
        else {
            throw ArchiveError.cannotCreateFile(destination.path)
        }

        let input = try FileHandle(forReadingFrom: source)
        let output: FileHandle
        do {
            output = try FileHandle(forWritingTo: destination)
        } catch let openError {
            try rethrowAfterClosing([input], operationError: openError)
        }
        var hasher = SHA256()
        var copiedBytes: UInt64 = 0
        do {
            while let chunk = try input.read(upToCount: copyChunkByteCount), !chunk.isEmpty {
                let (newCount, overflow) = copiedBytes.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow,
                    newCount <= maximumMemberByteCount,
                    newCount <= before.byteCount
                else {
                    throw ArchiveError.sourceChanged(source.path)
                }
                try output.write(contentsOf: chunk)
                hasher.update(data: chunk)
                copiedBytes = newCount
            }
            try output.synchronize()
            try input.close()
            try output.close()
        } catch let copyError {
            try rethrowAfterClosing([input, output], operationError: copyError)
        }

        let after = try observeSource(source, fileManager: fileManager)
        guard copiedBytes == before.byteCount,
            after.byteCount == before.byteCount,
            after.fileNumber == before.fileNumber,
            after.modifiedAt == before.modifiedAt
        else {
            throw ArchiveError.sourceChanged(source.path)
        }

        try beforeProtection()
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
        let digest = hasher.finalize().hexString
        let verified = try digestAndCount(destination, fileManager: fileManager)
        guard verified.byteCount == copiedBytes, verified.sha256 == digest else {
            throw ArchiveError.verificationFailed(destination.path)
        }
        return ArchiveMember(
            filename: source.lastPathComponent,
            byteCount: copiedBytes,
            sha256: digest
        )
    }

    private static func writeAndVerifyManifest(
        _ manifest: ArchiveManifest,
        in directory: URL,
        fileManager: FileManager
    ) throws {
        let manifestURL = try childURL(
            named: manifestFilename,
            in: directory,
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(manifest)
        guard encoded.count <= copyChunkByteCount,
            fileManager.createFile(
                atPath: manifestURL.path,
                contents: nil,
                attributes: [.protectionKey: LocalFileProtection.sensitive]
            )
        else {
            throw ArchiveError.cannotCreateFile(manifestURL.path)
        }
        let output = try FileHandle(forWritingTo: manifestURL)
        do {
            try output.write(contentsOf: encoded)
            try output.synchronize()
            try output.close()
        } catch let writeError {
            try rethrowAfterClosing([output], operationError: writeError)
        }
        try LocalFileProtection.protectItem(at: manifestURL, fileManager: fileManager)

        let attributes = try fileManager.attributesOfItem(atPath: manifestURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue == encoded.count else {
            throw ArchiveError.verificationFailed(manifestURL.path)
        }
        let verifiedData = try Data(contentsOf: manifestURL)
        guard verifiedData == encoded,
            try JSONDecoder().decode(ArchiveManifest.self, from: verifiedData) == manifest
        else {
            throw ArchiveError.verificationFailed(manifestURL.path)
        }
    }

    private static func digestAndCount(
        _ url: URL,
        fileManager: FileManager
    ) throws -> (byteCount: UInt64, sha256: String) {
        guard try itemType(at: url, fileManager: fileManager) == .typeRegular else {
            throw ArchiveError.unsupportedSource(url.path)
        }
        let input = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        do {
            while let chunk = try input.read(upToCount: copyChunkByteCount), !chunk.isEmpty {
                let (newCount, overflow) = byteCount.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, newCount <= maximumMemberByteCount else {
                    throw ArchiveError.sourceTooLarge(url.path)
                }
                hasher.update(data: chunk)
                byteCount = newCount
            }
            try input.close()
        } catch let digestError {
            try rethrowAfterClosing([input], operationError: digestError)
        }
        return (byteCount, hasher.finalize().hexString)
    }

    private static func rethrowAfterClosing(
        _ handles: [FileHandle],
        operationError: Error
    ) throws -> Never {
        var cleanupErrors: [Error] = []
        for handle in handles {
            do {
                try handle.close()
            } catch {
                cleanupErrors.append(error)
            }
        }
        if !cleanupErrors.isEmpty {
            throw ArchiveError.handleCleanupFailed(
                operation: operationError,
                cleanup: cleanupErrors
            )
        }
        throw operationError
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func removeInterruptedStagingDirectories(
        in root: URL,
        fileManager: FileManager
    ) throws {
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else { throw CocoaError(.fileReadUnknown) }
        while let child = enumerator.nextObject() as? URL {
            let name = child.lastPathComponent
            guard name.hasPrefix(".staging-"),
                UUID(uuidString: String(name.dropFirst(".staging-".count))) != nil,
                child.deletingLastPathComponent().standardizedFileURL == root,
                try itemType(at: child, fileManager: fileManager) == .typeDirectory
            else {
                continue
            }
            try fileManager.removeItem(at: child)
        }
        if let enumerationError { throw enumerationError }
    }

    private static func rotateArchives(
        in root: URL,
        retaining limit: Int,
        preserving current: URL,
        fileManager: FileManager
    ) throws {
        guard limit > 0 else { return }
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else { throw CocoaError(.fileReadUnknown) }
        let standardizedCurrent = current.standardizedFileURL
        let retainedOtherCount = max(0, limit - 1)
        var retained: [(url: URL, date: Date)] = []
        while let child = enumerator.nextObject() as? URL {
            guard child.deletingLastPathComponent().standardizedFileURL == root,
                UUID(uuidString: child.lastPathComponent) != nil,
                child.standardizedFileURL != standardizedCurrent,
                try itemType(at: child, fileManager: fileManager) == .typeDirectory
            else {
                continue
            }
            let values = try child.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            retained.append((child, values.creationDate ?? values.contentModificationDate ?? .distantPast))
            retained.sort {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            if retained.count > retainedOtherCount {
                let oldest = retained.removeLast()
                try fileManager.removeItem(at: oldest.url)
            }
        }
        if let enumerationError { throw enumerationError }
        try synchronizeDirectory(root)
    }
}

extension Digest {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
