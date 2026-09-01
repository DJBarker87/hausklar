import Foundation
import os

private let documentPreviewLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "DocumentPreviewStore"
)

@MainActor
enum DocumentPreviewStore {
    nonisolated private static let directoryName = "HausKlarPreviews"
    private(set) static var generation = 0
    /// Process-local cleanup capabilities. A URL with a plausible directory
    /// shape is not, by itself, authority to recursively delete that directory.
    private static var ownedPreviewDirectories: Set<URL> = []

    static func write(
        _ data: Data,
        filename: String,
        expectedGeneration: Int? = nil,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let expectedGeneration, expectedGeneration != generation {
            throw CancellationError()
        }
        guard data.count <= DocumentCaptureService.maximumFileBytes else {
            throw DocumentCaptureError.fileTooLarge
        }
        let targetGeneration = expectedGeneration ?? generation
        let root = rootDirectory ?? defaultDirectory(fileManager: fileManager)
        let url = try writeToDisk(
            data,
            filename: filename,
            generation: targetGeneration,
            root: root,
            fileManager: fileManager
        )
        ownedPreviewDirectories.insert(url.deletingLastPathComponent().standardizedFileURL)
        return url
    }

    nonisolated private static func writeToDisk(
        _ data: Data,
        filename: String,
        generation: Int,
        root: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard data.count <= DocumentCaptureService.maximumFileBytes else {
            throw DocumentCaptureError.fileTooLarge
        }
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let generationDirectory = root.appendingPathComponent(
            "generation-\(generation)",
            isDirectory: true
        )
        try LocalFileProtection.prepareDirectory(generationDirectory, fileManager: fileManager)
        let previewDirectory = generationDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try LocalFileProtection.prepareDirectory(previewDirectory, fileManager: fileManager)
        var shouldKeepDirectory = false
        defer {
            if !shouldKeepDirectory {
                removeDirectoryBestEffort(
                    previewDirectory,
                    fileManager: fileManager,
                    reason: "preview write rollback"
                )
            }
        }
        let safeFilename = safeFilename(filename)
        let url = previewDirectory.appendingPathComponent(safeFilename)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try LocalFileProtection.protectItem(at: url, fileManager: fileManager)
        shouldKeepDirectory = true
        return url
    }

    static func adoptDownloadedFile(
        _ sourceURL: URL,
        filename: String,
        expectedByteCount: Int? = nil,
        expectedMediaType: String? = nil,
        expectedGeneration: Int,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard expectedGeneration == generation else { throw CancellationError() }
        let root = rootDirectory ?? defaultDirectory(fileManager: fileManager)
        let previewURL = try adoptDownloadedFileOnDisk(
            sourceURL,
            filename: filename,
            expectedByteCount: expectedByteCount,
            expectedMediaType: expectedMediaType,
            generation: expectedGeneration,
            root: root,
            fileManager: fileManager
        )
        ownedPreviewDirectories.insert(
            previewURL.deletingLastPathComponent().standardizedFileURL
        )
        do {
            try Task.checkCancellation()
        } catch {
            remove(previewURL, rootDirectory: root, fileManager: fileManager)
            throw error
        }
        guard expectedGeneration == generation else {
            remove(previewURL, rootDirectory: root, fileManager: fileManager)
            throw CancellationError()
        }
        return previewURL
    }

    nonisolated private static func adoptDownloadedFileOnDisk(
        _ sourceURL: URL,
        filename: String,
        expectedByteCount: Int?,
        expectedMediaType: String?,
        generation: Int,
        root: URL,
        fileManager: FileManager
    ) throws -> URL {
        try Task.checkCancellation()
        let values = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let byteCount = values.fileSize,
            byteCount >= 0
        else {
            throw DocumentCaptureError.unreadableFile
        }
        guard byteCount <= DocumentCaptureService.maximumFileBytes else {
            throw DocumentCaptureError.fileTooLarge
        }
        if let expectedByteCount, expectedByteCount >= 0,
            byteCount != expectedByteCount
        {
            throw DocumentCaptureError.unreadableFile
        }
        if let expectedMediaType {
            try DocumentCaptureService.validateStoredFile(
                at: sourceURL,
                expectedMediaType: expectedMediaType
            )
        }

        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let generationDirectory = root.appendingPathComponent(
            "generation-\(generation)",
            isDirectory: true
        )
        try LocalFileProtection.prepareDirectory(generationDirectory, fileManager: fileManager)
        let previewDirectory = generationDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try LocalFileProtection.prepareDirectory(previewDirectory, fileManager: fileManager)
        var shouldKeepDirectory = false
        defer {
            if !shouldKeepDirectory {
                removeDirectoryBestEffort(
                    previewDirectory,
                    fileManager: fileManager,
                    reason: "downloaded preview adoption rollback"
                )
            }
        }
        let destination =
            previewDirectory
            .appendingPathComponent(safeFilename(filename), isDirectory: false)
            .standardizedFileURL
        guard destination.deletingLastPathComponent() == previewDirectory.standardizedFileURL else {
            throw DocumentCaptureError.unreadableFile
        }
        try fileManager.moveItem(at: sourceURL, to: destination)
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
        try Task.checkCancellation()
        shouldKeepDirectory = true
        return destination
    }

    nonisolated private static func safeFilename(_ filename: String) -> String {
        let invalid = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:"))
        let candidate = (filename as NSString).lastPathComponent
        guard !candidate.isEmpty,
            candidate != ".",
            candidate != "..",
            !candidate.hasPrefix("."),
            candidate.utf8.count <= 180,
            candidate.rangeOfCharacter(from: invalid) == nil
        else {
            return "document"
        }
        return candidate
    }

    static func remove(
        _ previewURL: URL,
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let root = (rootDirectory ?? defaultDirectory(fileManager: fileManager)).standardizedFileURL
        let file = previewURL.standardizedFileURL
        let previewDirectory = file.deletingLastPathComponent()
        let generationDirectory = previewDirectory.deletingLastPathComponent()
        let generationName = generationDirectory.lastPathComponent
        guard file.deletingLastPathComponent() == previewDirectory,
            UUID(uuidString: previewDirectory.lastPathComponent) != nil,
            generationDirectory.deletingLastPathComponent() == root,
            generationName.hasPrefix("generation-"),
            Int(generationName.dropFirst("generation-".count)) != nil,
            let generationValues = try? generationDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
            generationValues.isDirectory == true,
            generationValues.isSymbolicLink != true,
            let previewValues = try? previewDirectory.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
            previewValues.isDirectory == true,
            previewValues.isSymbolicLink != true,
            let fileValues = try? file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]),
            fileValues.isRegularFile == true,
            fileValues.isSymbolicLink != true
        else { return }
        guard ownedPreviewDirectories.contains(previewDirectory) else { return }
        if removeDirectoryBestEffort(
            previewDirectory,
            fileManager: fileManager,
            reason: "owned preview release"
        ) {
            ownedPreviewDirectories.remove(previewDirectory)
        }
    }

    static func purgeAll(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        generation &+= 1
        let root = rootDirectory ?? defaultDirectory(fileManager: fileManager)
        let standardizedRoot = root.standardizedFileURL
        ownedPreviewDirectories = ownedPreviewDirectories.filter {
            $0.deletingLastPathComponent().deletingLastPathComponent() != standardizedRoot
        }
        removeDirectoryBestEffort(
            root,
            fileManager: fileManager,
            reason: "preview purge"
        )
    }

    /// Invalidates previews immediately, then performs recursive deletion away
    /// from the launch render path. Moving within the temporary volume prevents
    /// the cleanup from deleting a new preview created after this call.
    static func purgeAllInBackground(fileManager: FileManager = .default) {
        generation &+= 1
        let root = defaultDirectory(fileManager: fileManager)
        let standardizedRoot = root.standardizedFileURL
        ownedPreviewDirectories = ownedPreviewDirectories.filter {
            $0.deletingLastPathComponent().deletingLastPathComponent() != standardizedRoot
        }
        let parent = root.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            sweepRetiredPreviewDirectories(in: parent, fileManager: FileManager())
        }
        guard fileManager.fileExists(atPath: root.path) else { return }
        let retired = root.deletingLastPathComponent().appendingPathComponent(
            "\(directoryName)-retired-\(UUID().uuidString)", isDirectory: true
        )
        do {
            try fileManager.moveItem(at: root, to: retired)
            Task.detached(priority: .utility) {
                removeDirectoryBestEffort(
                    retired,
                    fileManager: FileManager(),
                    reason: "retired preview purge"
                )
            }
        } catch {
            // Do not recursively delete after a failed move: a new generation
            // may have appeared at the original path while the move was failing.
            documentPreviewLogger.error(
                "Preview purge retirement failed closed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    nonisolated static func sweepRetiredPreviewDirectories(
        in parentDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumCandidates: Int = 256,
        maximumRemovals: Int = 32
    ) {
        // Stream the shared temporary directory instead of materializing it.
        // Only UUID-shaped HausKlar entries consume the candidate budget, so
        // unrelated provider files cannot permanently starve private cleanup.
        guard maximumCandidates > 0, maximumRemovals > 0 else { return }
        let parent = (parentDirectory ?? fileManager.temporaryDirectory).standardizedFileURL
        guard
            let enumerator = fileManager.enumerator(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in false }
            )
        else { return }
        let prefix = "\(directoryName)-retired-"
        var inspectedCandidates = 0
        var removed = 0
        while removed < maximumRemovals,
            let child = enumerator.nextObject() as? URL
        {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == parent,
                candidate.lastPathComponent.hasPrefix(prefix)
            else { continue }
            let suffix = String(candidate.lastPathComponent.dropFirst(prefix.count))
            guard UUID(uuidString: suffix) != nil else { continue }
            guard
                let values = try? candidate.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]),
                values.isDirectory == true,
                values.isSymbolicLink != true
            else { continue }
            guard inspectedCandidates < maximumCandidates else { break }
            inspectedCandidates += 1
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                continue
            }
        }
    }

    static func download(_ document: SourceDocumentDTO) async throws -> URL {
        try await download(
            documentId: document.id,
            filename: document.originalFilename,
            mediaType: document.mediaType,
            expectedByteCount: document.fileSize
        )
    }

    static func download(
        documentId: String,
        filename: String,
        mediaType: String,
        expectedByteCount: Int? = nil
    ) async throws -> URL {
        let expectedGeneration = generation
        let normalizedMediaType =
            mediaType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard DocumentCaptureService.allowedDocumentMediaTypes.contains(normalizedMediaType) else {
            throw DocumentCaptureError.unsupportedFile
        }
        if let expectedByteCount {
            guard expectedByteCount >= 0 else { throw DocumentCaptureError.unreadableFile }
            guard expectedByteCount <= DocumentCaptureService.maximumFileBytes else {
                throw DocumentCaptureError.fileTooLarge
            }
        }
        let temporaryURL = try await APIClient.shared.downloadToTemporaryFile(
            "/documents/\(documentId)/content",
            filename: filename,
            maximumBytes: DocumentCaptureService.maximumFileBytes,
            allowedMediaTypes: [normalizedMediaType]
        )
        let transferDirectory = temporaryURL.deletingLastPathComponent()
        defer {
            removeDirectoryBestEffort(
                transferDirectory,
                reason: "preview transfer release"
            )
        }
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }
        let root = defaultDirectory(fileManager: .default)
        let adoptionTask = Task.detached(priority: .userInitiated) {
            try adoptDownloadedFileOnDisk(
                temporaryURL,
                filename: "\(documentId)-\(filename)",
                expectedByteCount: expectedByteCount,
                expectedMediaType: normalizedMediaType,
                generation: expectedGeneration,
                root: root,
                fileManager: .default
            )
        }
        let previewURL = try await withTaskCancellationHandler {
            try await adoptionTask.value
        } onCancel: {
            adoptionTask.cancel()
        }
        ownedPreviewDirectories.insert(
            previewURL.deletingLastPathComponent().standardizedFileURL
        )
        do {
            try Task.checkCancellation()
        } catch {
            remove(previewURL)
            throw error
        }
        guard expectedGeneration == generation else {
            remove(previewURL)
            throw CancellationError()
        }
        return previewURL
    }

    @discardableResult
    nonisolated private static func removeDirectoryBestEffort(
        _ directory: URL,
        fileManager: FileManager = .default,
        reason: String
    ) -> Bool {
        do {
            try fileManager.removeItem(at: directory)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Cleanup is deliberately idempotent.
            return true
        } catch {
            documentPreviewLogger.error(
                "Best-effort \(reason, privacy: .public) cleanup failed for \(directory.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }
}
