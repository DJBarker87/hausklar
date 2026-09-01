import Foundation
import os
import UniformTypeIdentifiers

/// Foundation documents delegate-free `FileManager` operations as thread-safe.
/// The wrapper transfers the injected/default manager into one detached staging
/// operation, and HausKlar never installs a FileManager delegate.
private struct SchoolSendableFileManager: @unchecked Sendable {
    let value: FileManager
}

enum SchoolTimetableStagingError: LocalizedError {
    case invalidSource
    case unsupportedType
    case fileTooLarge
    case malformedDocument
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "The selected timetable is not a readable regular file."
        case .unsupportedType:
            return "Choose the Example School timetable as a .docx file."
        case .fileTooLarge:
            return "The Example School timetable must be 25 MB or smaller."
        case .malformedDocument:
            return "That file is not a valid Word document."
        case .sourceChanged:
            return "The selected timetable changed while HausKlar was preparing it."
        }
    }
}

/// A bounded, cancellable hand-off from a security-scoped document picker.
/// All reads and writes run on a detached executor; callers keep only the
/// returned protected file and remove its exact UUID-owned directory when done.
enum SchoolTimetableStaging {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "SchoolTimetableStaging"
    )

    struct StagedFile: Equatable, Sendable {
        let url: URL
        let originalFilename: String
        let byteCount: Int

        fileprivate var directory: URL { url.deletingLastPathComponent() }
    }

    static let maximumByteCount = 25 * 1_024 * 1_024
    static let mediaType =
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    private static let directoryName = "HausKlarSchoolTimetables"
    private static let chunkByteCount = 1_024 * 1_024
    private static let zipSignature = Data([0x50, 0x4B, 0x03, 0x04])

    static func stageSecurityScopedFile(
        at sourceURL: URL,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default,
        ioProbe: (@Sendable () -> Void)? = nil
    ) async throws -> StagedFile {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let root = rootDirectory ?? defaultRoot(fileManager: fileManager)
        let manager = SchoolSendableFileManager(value: fileManager)
        let task = Task.detached(priority: .userInitiated) {
            try stageOnDisk(
                sourceURL,
                rootDirectory: root,
                fileManager: manager.value,
                ioProbe: ioProbe
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func remove(
        _ stagedFile: StagedFile,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) async {
        let root = rootDirectory ?? defaultRoot(fileManager: fileManager)
        let manager = SchoolSendableFileManager(value: fileManager)
        await Task.detached(priority: .utility) {
            removeOnDisk(stagedFile, rootDirectory: root, fileManager: manager.value)
        }.value
    }

    /// Clears abandoned picker state on logout, account replacement, or a
    /// restored-session failure. The exact HausKlar root is removed only after
    /// verifying it is a real directory rather than a symlink.
    static func purgeAll(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) async throws {
        let root = rootDirectory ?? defaultRoot(fileManager: fileManager)
        let manager = SchoolSendableFileManager(value: fileManager)
        let task = Task.detached(priority: .utility) {
            try purgeAllOnDisk(rootDirectory: root, fileManager: manager.value)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func stageOnDisk(
        _ sourceURL: URL,
        rootDirectory: URL,
        fileManager: FileManager = .default,
        ioProbe: (@Sendable () -> Void)? = nil
    ) throws -> StagedFile {
        ioProbe?()
        try Task.checkCancellation()
        let source = sourceURL.standardizedFileURL
        guard source.isFileURL,
            source.pathExtension.lowercased() == "docx"
        else {
            throw SchoolTimetableStagingError.unsupportedType
        }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .contentTypeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let initial = try source.resourceValues(forKeys: keys)
        guard initial.isRegularFile == true,
            initial.isSymbolicLink != true,
            let expectedByteCount = initial.fileSize,
            expectedByteCount >= zipSignature.count
        else {
            throw SchoolTimetableStagingError.invalidSource
        }
        guard expectedByteCount <= maximumByteCount else {
            throw SchoolTimetableStagingError.fileTooLarge
        }
        guard isWordDocument(initial.contentType) else {
            throw SchoolTimetableStagingError.unsupportedType
        }

        let root = rootDirectory.standardizedFileURL
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let destination = directory.appendingPathComponent("example_school-timetable.docx")
        var keepDirectory = false
        defer {
            if !keepDirectory {
                removeInterruptedStage(directory, fileManager: fileManager)
            }
        }

        let input = try FileHandle(forReadingFrom: source)
        do {
            guard
                fileManager.createFile(
                    atPath: destination.path,
                    contents: nil,
                    attributes: [.protectionKey: LocalFileProtection.sensitive]
                )
            else {
                throw SchoolTimetableStagingError.invalidSource
            }
            let output = try FileHandle(forWritingTo: destination)
            do {
                var copiedByteCount = 0
                var prefix = Data()
                while true {
                    try Task.checkCancellation()
                    let remaining = maximumByteCount + 1 - copiedByteCount
                    guard remaining > 0 else {
                        throw SchoolTimetableStagingError.fileTooLarge
                    }
                    let chunk =
                        try input.read(
                            upToCount: min(chunkByteCount, remaining)
                        ) ?? Data()
                    if chunk.isEmpty { break }
                    if prefix.count < zipSignature.count {
                        prefix.append(chunk.prefix(zipSignature.count - prefix.count))
                    }
                    copiedByteCount += chunk.count
                    guard copiedByteCount <= maximumByteCount else {
                        throw SchoolTimetableStagingError.fileTooLarge
                    }
                    try output.write(contentsOf: chunk)
                }
                try output.synchronize()
                try output.close()
                try input.close()

                guard copiedByteCount == expectedByteCount,
                    prefix == zipSignature
                else {
                    throw SchoolTimetableStagingError.malformedDocument
                }
                let finalSource = try source.resourceValues(forKeys: keys)
                let finalDestination = try destination.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard finalSource.isRegularFile == true,
                    finalSource.isSymbolicLink != true,
                    finalSource.fileSize == expectedByteCount,
                    finalSource.contentModificationDate == initial.contentModificationDate,
                    finalDestination.isRegularFile == true,
                    finalDestination.isSymbolicLink != true,
                    finalDestination.fileSize == copiedByteCount
                else {
                    throw SchoolTimetableStagingError.sourceChanged
                }
                try LocalFileProtection.protectItem(
                    at: destination,
                    fileManager: fileManager
                )
                try Task.checkCancellation()
                keepDirectory = true
                return StagedFile(
                    url: destination,
                    originalFilename: safeOriginalFilename(source.lastPathComponent),
                    byteCount: copiedByteCount
                )
            } catch {
                closeAfterFailure(output, role: "output")
                throw error
            }
        } catch {
            closeAfterFailure(input, role: "input")
            throw error
        }
    }

    nonisolated private static func removeOnDisk(
        _ stagedFile: StagedFile,
        rootDirectory: URL,
        fileManager: FileManager
    ) {
        let root = rootDirectory.standardizedFileURL
        let directory = stagedFile.directory.standardizedFileURL
        // Resource inspection is a fail-closed ownership probe; failure grants
        // no deletion authority.
        guard directory.deletingLastPathComponent() == root,
            isCanonicalLowercaseUUID(directory.lastPathComponent),
            stagedFile.url.standardizedFileURL.deletingLastPathComponent() == directory,
            stagedFile.url.lastPathComponent == "example_school-timetable.docx",
            let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else { return }
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "Could not remove an owned timetable stage: \(error.localizedDescription, privacy: .public). Reconciliation: the account-transition purge retries the exact staging root."
            )
        }
    }

    nonisolated private static func purgeAllOnDisk(
        rootDirectory: URL,
        fileManager: FileManager
    ) throws {
        try Task.checkCancellation()
        let root = rootDirectory.standardizedFileURL
        guard fileManager.fileExists(atPath: root.path) else { return }
        let values = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw SchoolTimetableStagingError.invalidSource
        }
        try fileManager.removeItem(at: root)
        guard !fileManager.fileExists(atPath: root.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    nonisolated private static func isWordDocument(_ type: UTType?) -> Bool {
        guard let type else { return false }
        let expected = UTType(filenameExtension: "docx")
        return type.identifier == expected?.identifier
            || type.preferredMIMEType?.lowercased() == mediaType
    }

    nonisolated private static func safeOriginalFilename(_ value: String) -> String {
        let candidate = (value as NSString).lastPathComponent
        let invalid = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        guard !candidate.isEmpty,
            candidate.utf8.count <= 180,
            candidate.rangeOfCharacter(from: invalid) == nil
        else {
            return "Example School timetable.docx"
        }
        return candidate
    }

    nonisolated private static func defaultRoot(fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
    }

    nonisolated private static func isCanonicalLowercaseUUID(_ value: String) -> Bool {
        value.count == 36
            && value == value.lowercased()
            && UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    nonisolated private static func removeInterruptedStage(
        _ directory: URL,
        fileManager: FileManager
    ) {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            logger.error(
                "Could not remove an interrupted timetable stage: \(error.localizedDescription, privacy: .public). Reconciliation: the account-transition purge retries the exact staging root."
            )
        }
    }

    nonisolated private static func closeAfterFailure(
        _ handle: FileHandle,
        role: String
    ) {
        do {
            try handle.close()
        } catch {
            logger.error(
                "Could not close timetable \(role, privacy: .public) after failure: \(error.localizedDescription, privacy: .public). The handle remains process-owned and closes on deallocation."
            )
        }
    }
}
