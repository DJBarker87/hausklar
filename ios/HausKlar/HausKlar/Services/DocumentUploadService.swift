import Darwin
import Foundation
import os
import SwiftData

private let documentUploadLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "DocumentUploadService"
)

@MainActor
final class DocumentUploadService {
    struct IdentityLease: Equatable, Sendable {
        fileprivate let identity: String
        fileprivate let epoch: Int
    }

    enum QueueError: LocalizedError {
        case acknowledgementCouldNotBeSaved
        case queueStateCouldNotBeSaved
        case stagedFileMissing
        case uploadAlreadyInProgress
        case permanentFailure(String)

        var errorDescription: String? {
            switch self {
            case .acknowledgementCouldNotBeSaved:
                "The upload succeeded, but its receipt could not be saved. The secure original was kept for a safe retry."
            case .queueStateCouldNotBeSaved:
                "The upload state could not be saved. The secure original was kept and will be recovered safely."
            case .stagedFileMissing:
                "The secure local copy is missing. Capture the document again."
            case .uploadAlreadyInProgress:
                "This document is already uploading."
            case .permanentFailure(let message):
                message
            }
        }
    }

    typealias UploadOperation = (
        _ fileURL: URL,
        _ filename: String,
        _ mediaType: String,
        _ fields: [String: String]
    ) async throws -> DocumentDTO
    typealias RemoveDirectoryOperation = (_ directory: URL) async throws -> Void
    typealias SaveOperation = (_ modelContext: ModelContext) throws -> Void
    typealias FetchOperation = (_ modelContext: ModelContext) throws -> [PendingDocumentUpload]

    struct StagedUpload: Sendable {
        let directory: URL
        let destination: URL
    }
    typealias StageOperation = (
        _ sourceURL: URL,
        _ filename: String,
        _ id: String,
        _ root: URL
    ) async throws -> StagedUpload

    private struct FlushRun {
        let id: UUID
        let lease: IdentityLease
        let task: Task<Void, Never>
    }

    private struct UploadRun {
        let id: UUID
        let task: Task<DocumentDTO, Error>
    }

    private struct OrphanReconciliationRun {
        let id: UUID
        let task: Task<Int, Never>
    }

    private enum FailureDisposition {
        case authentication
        case retryable(String)
        case permanent(String)
        case cancelled
    }

    static let shared = DocumentUploadService()

    private let fileManager: FileManager
    private let uploadsRootOverride: URL?
    private let uploadOperation: UploadOperation
    private let stageOperation: StageOperation
    private let removeDirectoryOperation: RemoveDirectoryOperation
    private let saveOperation: SaveOperation
    private let fetchOperation: FetchOperation
    private let now: () -> Date
    private let orphanMinimumAge: TimeInterval
    private let orphanMaximumCandidates: Int
    private let orphanMaximumRemovals: Int
    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    private let acknowledgementEncoder = JSONEncoder()
    private let acknowledgementDecoder = JSONDecoder()
    private var activeIdentity: String?
    private var identityEpoch = 0
    private var flushRun: FlushRun?
    private var stagingTasks: [String: Task<StagedUpload, Error>] = [:]
    private var uploadRuns: [String: UploadRun] = [:]
    private var orphanReconciliationRun: OrphanReconciliationRun?

    init(
        fileManager: FileManager = .default,
        uploadsRoot: URL? = nil,
        uploadOperation: UploadOperation? = nil,
        stageOperation: StageOperation? = nil,
        removeDirectoryOperation: RemoveDirectoryOperation? = nil,
        saveOperation: SaveOperation? = nil,
        fetchOperation: FetchOperation? = nil,
        now: @escaping () -> Date = Date.init,
        orphanMinimumAge: TimeInterval = 24 * 60 * 60,
        orphanMaximumCandidates: Int = 256,
        orphanMaximumRemovals: Int = 32
    ) {
        self.fileManager = fileManager
        uploadsRootOverride = uploadsRoot
        self.uploadOperation =
            uploadOperation ?? { fileURL, filename, mediaType, fields in
                try await APIClient.shared.uploadMultipart(
                    "/documents/",
                    fileURL: fileURL,
                    filename: filename,
                    mediaType: mediaType,
                    fields: fields,
                    offlineReplayPolicy: .callerManaged
                )
            }
        self.stageOperation =
            stageOperation ?? { sourceURL, filename, id, root in
                try await Task.detached(priority: .userInitiated) {
                    try Self.stageUploadFile(
                        sourceURL: sourceURL,
                        filename: filename,
                        id: id,
                        root: root
                    )
                }.value
            }
        self.removeDirectoryOperation =
            removeDirectoryOperation ?? { directory in
                try await Task.detached(priority: .utility) {
                    guard FileManager.default.fileExists(atPath: directory.path) else { return }
                    let values = try directory.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                    ])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw DocumentCaptureError.unreadableFile
                    }
                    try FileManager.default.removeItem(at: directory)
                }.value
            }
        self.saveOperation = saveOperation ?? { try $0.save() }
        self.fetchOperation = fetchOperation ?? {
            try $0.fetch(FetchDescriptor<PendingDocumentUpload>())
        }
        self.now = now
        self.orphanMinimumAge = max(0, orphanMinimumAge)
        self.orphanMaximumCandidates = max(0, orphanMaximumCandidates)
        self.orphanMaximumRemovals = max(0, orphanMaximumRemovals)
    }

    func activate(identity: String) {
        cancelOwnedWork()
        activeIdentity = identity
        identityEpoch &+= 1
        Task.detached(priority: .utility) {
            DocumentCaptureService.sweepRetiredTemporaryCaptures()
            DocumentPreviewStore.sweepRetiredPreviewDirectories()
            PhotoUploadPrep.reconcileStagedFiles()
        }
    }

    func suspend() {
        activeIdentity = nil
        identityEpoch &+= 1
        cancelOwnedWork()
    }

    /// Integration point for lifecycle owners that can await teardown. Existing
    /// synchronous callers still invalidate leases and cancel work immediately.
    func waitForSuspendedWork() async {
        let flush = flushRun?.task
        let staging = Array(stagingTasks.values)
        let uploads = uploadRuns.values.map(\.task)
        let orphanReconciliation = orphanReconciliationRun?.task
        _ = await flush?.value
        for task in staging {
            await observeOwnedTaskCompletion(task, operation: "staging")
        }
        for task in uploads {
            await observeOwnedTaskCompletion(task, operation: "upload")
        }
        _ = await orphanReconciliation?.value
    }

    private func observeOwnedTaskCompletion<Value>(
        _ task: Task<Value, Error>,
        operation: String
    ) async {
        do {
            _ = try await task.value
        } catch is CancellationError {
            // Cancellation is the expected result after suspend/account change.
        } catch {
            documentUploadLogger.error(
                "Owned \(operation, privacy: .public) task ended with an error during teardown: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    var currentIdentityLease: IdentityLease? {
        guard let activeIdentity else { return nil }
        return IdentityLease(identity: activeIdentity, epoch: identityEpoch)
    }

    private func isCurrent(_ identityLease: IdentityLease) -> Bool {
        currentIdentityLease == identityLease
    }

    private func cancelOwnedWork() {
        flushRun?.task.cancel()
        for task in stagingTasks.values { task.cancel() }
        for run in uploadRuns.values { run.task.cancel() }
        orphanReconciliationRun?.task.cancel()
    }

    func enqueue(
        asset: CapturedDocumentAsset,
        title: String,
        category: DocumentCategory,
        documentDate: Date?,
        extractedText: String,
        notes: String,
        personIds: [String],
        suggestions: [CaptureSuggestionDraft],
        useHermes: Bool,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) throws -> PendingDocumentUpload {
        guard isCurrent(expectedIdentityLease) else {
            throw DocumentCaptureError.accountUnavailable
        }
        let id = UUID().uuidString
        let directory = try uploadsDirectory().appendingPathComponent(id, isDirectory: true)
        var shouldKeepDirectory = false
        defer {
            if !shouldKeepDirectory {
                Self.removeStagingDirectoryBestEffort(
                    directory,
                    fileManager: fileManager,
                    reason: "synchronous enqueue rollback"
                )
            }
        }
        try Self.validateStagingSource(asset.fileURL)
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let candidate = (asset.filename as NSString).lastPathComponent
        let safeFilename = candidate.isEmpty ? "document" : candidate
        let destination = directory.appendingPathComponent(safeFilename)
        try fileManager.copyItem(at: asset.fileURL, to: destination)
        try Self.validateStagingSource(destination)
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)

        let peopleData = try JSONSerialization.data(withJSONObject: personIds)
        let includedSuggestions = suggestions.filter(\.isIncluded)
        let pending = PendingDocumentUpload(
            id: id,
            filePath: destination.path,
            filename: asset.filename,
            mediaType: asset.mediaType,
            title: title,
            source: asset.source,
            category: category.rawValue,
            documentDate: documentDate.map(ISODateParser.dateOnly),
            pageCount: asset.pageCount,
            extractedText: extractedText.isEmpty ? nil : extractedText,
            notes: notes.isEmpty ? nil : notes,
            personIdsJSON: String(data: peopleData, encoding: .utf8) ?? "[]",
            suggestionsJSON: String(
                data: try jsonEncoder.encode(includedSuggestions),
                encoding: .utf8
            ) ?? "[]",
            useHermes: useHermes
        )
        modelContext.insert(pending)
        do {
            try saveOperation(modelContext)
        } catch {
            modelContext.delete(pending)
            throw error
        }
        shouldKeepDirectory = true
        return pending
    }

    /// Stages potentially large scans away from the main actor, then performs
    /// only the SwiftData insertion after the identity lease is revalidated.
    func enqueueWithoutBlockingUI(
        asset: CapturedDocumentAsset,
        title: String,
        category: DocumentCategory,
        documentDate: Date?,
        extractedText: String,
        notes: String,
        personIds: [String],
        suggestions: [CaptureSuggestionDraft],
        useHermes: Bool,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) async throws -> PendingDocumentUpload {
        guard isCurrent(expectedIdentityLease) else {
            throw DocumentCaptureError.accountUnavailable
        }
        let id = UUID().uuidString
        let sourceURL = asset.fileURL
        let filename = asset.filename
        let root = try uploadsDirectory()
        let stagingTask = Task {
            try await stageOperation(sourceURL, filename, id, root)
        }
        stagingTasks[id] = stagingTask
        let staged: StagedUpload
        do {
            staged = try await withTaskCancellationHandler {
                try await stagingTask.value
            } onCancel: {
                stagingTask.cancel()
            }
        } catch {
            stagingTasks[id] = nil
            throw error
        }
        stagingTasks[id] = nil
        var shouldKeepDirectory = false
        defer {
            if !shouldKeepDirectory {
                Self.removeStagingDirectoryBestEffort(
                    staged.directory,
                    fileManager: fileManager,
                    reason: "asynchronous enqueue rollback"
                )
            }
        }
        guard isCurrent(expectedIdentityLease) else {
            throw DocumentCaptureError.accountUnavailable
        }
        let peopleData = try JSONSerialization.data(withJSONObject: personIds)
        let includedSuggestions = suggestions.filter(\.isIncluded)
        let pending = PendingDocumentUpload(
            id: id, filePath: staged.destination.path, filename: asset.filename,
            mediaType: asset.mediaType, title: title, source: asset.source,
            category: category.rawValue, documentDate: documentDate.map(ISODateParser.dateOnly),
            pageCount: asset.pageCount, extractedText: extractedText.isEmpty ? nil : extractedText,
            notes: notes.isEmpty ? nil : notes,
            personIdsJSON: String(data: peopleData, encoding: .utf8) ?? "[]",
            suggestionsJSON: String(
                data: try jsonEncoder.encode(includedSuggestions), encoding: .utf8
            ) ?? "[]", useHermes: useHermes
        )
        modelContext.insert(pending)
        do {
            try saveOperation(modelContext)
        } catch {
            modelContext.delete(pending)
            throw error
        }
        shouldKeepDirectory = true
        return pending
    }

    nonisolated private static func stageUploadFile(
        sourceURL: URL,
        filename: String,
        id: String,
        root: URL,
        fileManager: FileManager = .default
    ) throws -> StagedUpload {
        try Task.checkCancellation()
        try validateStagingSource(sourceURL)
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let directory = root.appendingPathComponent(id, isDirectory: true)
        var shouldKeepDirectory = false
        defer {
            if !shouldKeepDirectory {
                removeStagingDirectoryBestEffort(
                    directory,
                    fileManager: fileManager,
                    reason: "detached staging rollback"
                )
            }
        }
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let candidate = (filename as NSString).lastPathComponent
        let safeFilename = candidate.isEmpty ? "document" : candidate
        let destination = directory.appendingPathComponent(safeFilename)
        try fileManager.copyItem(at: sourceURL, to: destination)
        try Task.checkCancellation()
        try validateStagingSource(destination)
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
        try Task.checkCancellation()
        shouldKeepDirectory = true
        return StagedUpload(directory: directory, destination: destination)
    }

    nonisolated private static func removeStagingDirectoryBestEffort(
        _ directory: URL,
        fileManager: FileManager,
        reason: String
    ) {
        do {
            try fileManager.removeItem(at: directory)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Cleanup is deliberately idempotent.
        } catch {
            documentUploadLogger.error(
                "Best-effort \(reason, privacy: .public) cleanup failed for \(directory.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    nonisolated private static func validateStagingSource(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let byteCount = values.fileSize,
            byteCount > 0,
            byteCount <= DocumentCaptureService.maximumFileBytes
        else {
            throw DocumentCaptureError.unreadableFile
        }
    }

    func upload(
        _ pending: PendingDocumentUpload,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) async throws -> DocumentDTO {
        guard isCurrent(expectedIdentityLease) else {
            throw DocumentCaptureError.accountUnavailable
        }
        if let acknowledged = acknowledgedDocument(for: pending) {
            try await finishAcknowledgedUpload(
                pending,
                document: acknowledged,
                modelContext: modelContext,
                expectedIdentityLease: expectedIdentityLease
            )
            return acknowledged
        }
        if pending.status == .permanentFailure || pending.status == .failed {
            throw QueueError.permanentFailure(
                pending.errorMessage ?? "This upload needs to be discarded and captured again."
            )
        }
        guard uploadRuns[pending.id] == nil else { throw QueueError.uploadAlreadyInProgress }
        let fileURL = URL(fileURLWithPath: pending.filePath)
        guard try isValidatedPendingFile(pending) else {
            pending.status = .permanentFailure
            pending.failureKind = "missing_file"
            pending.errorMessage = QueueError.stagedFileMissing.errorDescription
            try saveOperation(modelContext)
            throw QueueError.stagedFileMissing
        }
        try LocalFileProtection.protectItem(at: fileURL, fileManager: fileManager)
        pending.status = .uploading
        pending.errorMessage = nil
        pending.failureKind = nil
        pending.lastAttemptAt = now()
        try saveOperation(modelContext)

        let fields = multipartFields(for: pending)

        do {
            let requestID = UUID()
            let requestTask = Task {
                try await uploadOperation(fileURL, pending.filename, pending.mediaType, fields)
            }
            uploadRuns[pending.id] = UploadRun(id: requestID, task: requestTask)
            let document: DocumentDTO
            do {
                document = try await withTaskCancellationHandler {
                    try await requestTask.value
                } onCancel: {
                    requestTask.cancel()
                }
            } catch {
                if uploadRuns[pending.id]?.id == requestID { uploadRuns[pending.id] = nil }
                throw error
            }
            if uploadRuns[pending.id]?.id == requestID { uploadRuns[pending.id] = nil }
            let receipt = try acknowledgementEncoder.encode(document)
            pending.status = .acknowledgedPendingCleanup
            pending.acknowledgedDocumentJSON = receipt
            pending.acknowledgedAt = now()
            pending.nextAttemptAt = nil
            pending.errorMessage = nil
            pending.failureKind = nil
            do {
                try saveOperation(modelContext)
            } catch {
                // Do not cross the acknowledgement boundary without a durable
                // receipt. Retain the file and replay the same stable UUID.
                pending.status = .pending
                pending.acknowledgedDocumentJSON = nil
                pending.acknowledgedAt = nil
                pending.errorMessage = QueueError.acknowledgementCouldNotBeSaved.errorDescription
                pending.failureKind = "ack_persistence"
                // The pre-upload `.uploading` marker is already durable and is
                // safely replayed by `recoverInterruptedUploads`. Surface a
                // second persistence failure instead of pretending the
                // diagnostic rollback was saved.
                do {
                    try saveOperation(modelContext)
                } catch {
                    documentUploadLogger.fault(
                        "Failed to persist the replay-safe acknowledgement rollback: \(error.localizedDescription, privacy: .private)"
                    )
                    throw QueueError.queueStateCouldNotBeSaved
                }
                throw QueueError.acknowledgementCouldNotBeSaved
            }
            guard isCurrent(expectedIdentityLease) else {
                throw DocumentCaptureError.accountUnavailable
            }
            try await finishAcknowledgedUpload(
                pending,
                document: document,
                modelContext: modelContext,
                expectedIdentityLease: expectedIdentityLease
            )
            return document
        } catch {
            if pending.acknowledgedDocumentJSON != nil {
                throw error
            }
            if let queueError = error as? QueueError {
                switch queueError {
                case .acknowledgementCouldNotBeSaved, .queueStateCouldNotBeSaved:
                    // The inner boundary handler restored a replay-safe pending
                    // state. Do not overwrite it as a generic transport retry.
                    throw queueError
                case .stagedFileMissing, .uploadAlreadyInProgress, .permanentFailure:
                    break
                }
            }
            let uploadError = error
            applyFailure(uploadError, to: pending)
            // If this save fails, the earlier durable `.uploading` marker remains
            // replay-safe. The persistence error is more actionable than the
            // transport failure and must reach the caller.
            try saveOperation(modelContext)
            throw uploadError
        }
    }

    func multipartFields(for pending: PendingDocumentUpload) -> [String: String] {
        var fields = [
            "document_id": pending.id,
            "title": pending.title,
            "source": pending.source,
            "category": pending.category,
            "page_count": String(pending.pageCount),
            "person_ids": pending.personIdsJSON,
            "suggestions": pending.suggestionsJSON,
            "use_hermes": pending.useHermes ? "true" : "false",
        ]
        if let date = pending.documentDate { fields["document_date"] = date }
        if let text = pending.extractedText { fields["extracted_text"] = text }
        if let notes = pending.notes { fields["notes"] = notes }
        return fields
    }

    func flush(modelContext: ModelContext) async {
        guard let identityLease = currentIdentityLease else { return }
        if let existing = flushRun {
            await existing.task.value
            if flushRun?.id == existing.id { flushRun = nil }
            if existing.lease == identityLease { return }
            guard isCurrent(identityLease) else { return }
        }
        let runID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performFlush(modelContext: modelContext, expectedIdentityLease: identityLease)
        }
        flushRun = FlushRun(id: runID, lease: identityLease, task: task)
        await task.value
        if flushRun?.id == runID { flushRun = nil }
    }

    private func performFlush(
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) async {
        guard isCurrent(expectedIdentityLease), !Task.isCancelled else { return }
        do {
            try await reconcile(
                modelContext: modelContext,
                expectedIdentityLease: expectedIdentityLease
            )
        } catch {
            // Leave the durable queue untouched for the next lifecycle/network
            // flush; proceeding after a fetch/save failure could cross a state
            // boundary using an incomplete view of the queue.
            documentUploadLogger.error(
                "Document queue reconciliation failed closed: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        // SwiftData's key-path sort descriptor is not Sendable under complete
        // concurrency checking. Queue cardinality is intentionally small, so a
        // deterministic main-actor sort avoids carrying that unsafe key path.
        let fetchedUploads: [PendingDocumentUpload]
        do {
            fetchedUploads = try fetchOperation(modelContext)
        } catch {
            documentUploadLogger.error(
                "Document queue fetch failed closed during flush: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        let pendingUploads = fetchedUploads.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
        for pending in pendingUploads {
            guard isCurrent(expectedIdentityLease), !Task.isCancelled else { break }
            if pending.status == .acknowledgedPendingCleanup || pending.status == .complete {
                do {
                    try await reconcileAcknowledged(
                        pending,
                        modelContext: modelContext,
                        expectedIdentityLease: expectedIdentityLease
                    )
                } catch {
                    documentUploadLogger.error(
                        "Acknowledged upload reconciliation failed closed: \(error.localizedDescription, privacy: .private)"
                    )
                    return
                }
                continue
            }
            guard pending.status.mayUploadAutomatically else { continue }
            if let nextAttemptAt = pending.nextAttemptAt, nextAttemptAt > now() { continue }
            do {
                _ = try await upload(
                    pending,
                    modelContext: modelContext,
                    expectedIdentityLease: expectedIdentityLease
                )
            } catch {
                if pending.failureKind == "authentication" { break }
            }
        }
    }

    /// `.uploading` is only an in-process marker. If the app was killed after the
    /// server commit, replaying the same stable document UUID is safe and returns
    /// the already-created document instead of creating a duplicate.
    func recoverInterruptedUploads(
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) throws {
        guard isCurrent(expectedIdentityLease) else { return }
        let uploads = try fetchOperation(modelContext)
        let interrupted = uploads.filter { $0.status == .uploading }
        guard !interrupted.isEmpty else { return }
        for pending in interrupted {
            pending.status = .pending
            pending.errorMessage = "The previous upload was interrupted and will retry safely."
            pending.failureKind = "interrupted"
            pending.nextAttemptAt = nil
        }
        try saveOperation(modelContext)
    }

    func reconcile(
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) async throws {
        guard isCurrent(expectedIdentityLease) else { return }
        try recoverInterruptedUploads(
            modelContext: modelContext,
            expectedIdentityLease: expectedIdentityLease
        )
        let uploads = try fetchOperation(modelContext)
        var changed = false
        for pending in uploads {
            guard isCurrent(expectedIdentityLease), !Task.isCancelled else { return }
            if pending.status == .failed {
                pending.status = .permanentFailure
                pending.failureKind = pending.failureKind ?? "legacy_failure"
                changed = true
            } else if pending.status == .retryableFailure,
                pending.failureKind == "authentication"
            {
                pending.status = .pending
                pending.nextAttemptAt = nil
                changed = true
            }
            let fileIsValid = try isValidatedPendingFile(pending)
            if !fileIsValid,
                pending.status != .acknowledgedPendingCleanup,
                pending.status != .complete
            {
                pending.status = .permanentFailure
                pending.failureKind = "missing_file"
                pending.errorMessage = QueueError.stagedFileMissing.errorDescription
                changed = true
            }
        }
        if changed { try saveOperation(modelContext) }

        for pending in uploads where pending.status == .acknowledgedPendingCleanup || pending.status == .complete {
            try await reconcileAcknowledged(
                pending,
                modelContext: modelContext,
                expectedIdentityLease: expectedIdentityLease
            )
        }
        await reconcileOrphanUploadDirectories(
            uploads: uploads,
            expectedIdentityLease: expectedIdentityLease
        )
    }

    @discardableResult
    func discard(
        _ pending: PendingDocumentUpload,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) async throws -> Bool {
        guard isCurrent(expectedIdentityLease) else { return false }
        guard pending.status != .uploading,
            pending.status != .acknowledgedPendingCleanup
        else { return false }
        guard let directory = try ownedUploadDirectory(for: pending) else {
            pending.status = .permanentFailure
            pending.failureKind = "unsafe_path"
            pending.errorMessage = QueueError.stagedFileMissing.errorDescription
            try saveOperation(modelContext)
            return false
        }
        do {
            try await removeDirectoryOperation(directory)
        } catch {
            pending.status = .permanentFailure
            pending.failureKind = "discard_cleanup"
            pending.errorMessage = "The local file could not be removed. Try discarding it again."
            try saveOperation(modelContext)
            return false
        }
        modelContext.delete(pending)
        try saveOperation(modelContext)
        return true
    }

    nonisolated static func hardenStoredUploadsOnDisk(fileManager: FileManager = .default) {
        let support: URL
        do {
            support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            documentUploadLogger.error(
                "Could not resolve document upload storage for hardening: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        let root = support.appendingPathComponent("DocumentUploads", isDirectory: true)
        do {
            try LocalFileProtection.protectDirectoryRecursively(root, fileManager: fileManager)
        } catch {
            // This launch-time pass repairs legacy protection. New writes still
            // enforce protection synchronously and fail if that cannot be done.
            documentUploadLogger.error(
                "Best-effort legacy upload hardening failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func uploadsDirectory() throws -> URL {
        let root: URL
        if let uploadsRootOverride {
            root = uploadsRootOverride
        } else {
            root = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("DocumentUploads", isDirectory: true)
        }
        try LocalFileProtection.prepareDirectory(root, fileManager: fileManager)
        let standardizedRoot = root.standardizedFileURL
        let values = try standardizedRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DocumentCaptureError.unreadableFile
        }
        return standardizedRoot
    }

    /// Resolves a queue row only to its exact app-owned UUID directory. Missing
    /// directories are returned so acknowledgement/discard cleanup stays
    /// idempotent, but symlinks and path traversal are rejected.
    private func ownedUploadDirectory(for pending: PendingDocumentUpload) throws -> URL? {
        guard UUID(uuidString: pending.id) != nil else { return nil }
        let root = try uploadsDirectory()
        let expected = root.appendingPathComponent(pending.id, isDirectory: true)
            .standardizedFileURL
        let file = URL(fileURLWithPath: pending.filePath).standardizedFileURL
        guard expected.deletingLastPathComponent() == root,
            file.deletingLastPathComponent() == expected
        else { return nil }

        do {
            let values = try expected.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        } catch where Self.isNoSuchFileError(error) {
            // Missing directories are valid idempotent cleanup targets, but a
            // broken symlink must never be mistaken for absence.
            guard try Self.pathIsAbsent(expected) else { return nil }
        }
        return expected
    }

    private func isValidatedPendingFile(_ pending: PendingDocumentUpload) throws -> Bool {
        guard let directory = try ownedUploadDirectory(for: pending) else { return false }
        let file = URL(fileURLWithPath: pending.filePath).standardizedFileURL
        guard file.deletingLastPathComponent() == directory else { return false }
        do {
            let values = try file.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let byteCount = values.fileSize,
                byteCount > 0,
                byteCount <= DocumentCaptureService.maximumFileBytes
            else { return false }
            return true
        } catch where Self.isNoSuchFileError(error) {
            return false
        }
    }

    nonisolated private static func pathIsAbsent(_ url: URL) throws -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 { return false }
        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    nonisolated private static func isNoSuchFileError(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && (cocoaError.code == NSFileNoSuchFileError
                || cocoaError.code == NSFileReadNoSuchFileError)
    }

    private func acknowledgedDocument(for pending: PendingDocumentUpload) -> DocumentDTO? {
        guard let data = pending.acknowledgedDocumentJSON else { return nil }
        return try? acknowledgementDecoder.decode(DocumentDTO.self, from: data)
    }

    private func finishAcknowledgedUpload(
        _ pending: PendingDocumentUpload,
        document: DocumentDTO,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) async throws {
        guard isCurrent(expectedIdentityLease) else { return }
        guard let directory = try ownedUploadDirectory(for: pending) else {
            pending.status = .acknowledgedPendingCleanup
            pending.failureKind = "unsafe_path"
            pending.errorMessage = "Uploaded successfully. The protected local path needs review."
            try saveOperation(modelContext)
            return
        }
        do {
            try await removeDirectoryOperation(directory)
        } catch {
            pending.status = .acknowledgedPendingCleanup
            pending.failureKind = "cleanup"
            pending.errorMessage = "Uploaded successfully. Secure local cleanup will retry automatically."
            try saveOperation(modelContext)
            return
        }
        guard isCurrent(expectedIdentityLease) else { return }
        pending.status = .complete
        pending.failureKind = nil
        pending.errorMessage = nil
        do {
            try saveOperation(modelContext)
        } catch {
            pending.status = .acknowledgedPendingCleanup
            pending.failureKind = "completion_persistence"
            pending.errorMessage = "Uploaded successfully. Queue cleanup will retry automatically."
            do {
                try saveOperation(modelContext)
            } catch {
                documentUploadLogger.fault(
                    "Failed to restore acknowledged cleanup state after completion persistence failure: \(error.localizedDescription, privacy: .private)"
                )
                throw QueueError.queueStateCouldNotBeSaved
            }
            return
        }
        modelContext.delete(pending)
        // `.complete` is already durable. If deleting the row fails, surface the
        // error and let reconciliation retry without ever re-uploading.
        try saveOperation(modelContext)
        _ = document
    }

    private func reconcileAcknowledged(
        _ pending: PendingDocumentUpload,
        modelContext: ModelContext,
        expectedIdentityLease: IdentityLease
    ) async throws {
        if pending.status == .complete {
            modelContext.delete(pending)
            try saveOperation(modelContext)
            return
        }
        guard let document = acknowledgedDocument(for: pending) else {
            // A pre-release state could not have a receipt. Fail visibly rather
            // than crossing the boundary or issuing an ambiguous re-upload.
            pending.status = .permanentFailure
            pending.failureKind = "invalid_acknowledgement"
            pending.errorMessage = "The saved upload receipt is unreadable. The secure original was kept."
            try saveOperation(modelContext)
            return
        }
        try await finishAcknowledgedUpload(
            pending,
            document: document,
            modelContext: modelContext,
            expectedIdentityLease: expectedIdentityLease
        )
    }

    private func applyFailure(_ error: Error, to pending: PendingDocumentUpload) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        switch failureDisposition(for: error) {
        case .cancelled:
            pending.status = .pending
            pending.failureKind = "interrupted"
            pending.nextAttemptAt = nil
        case .authentication:
            pending.status = .retryableFailure
            pending.failureKind = "authentication"
            pending.nextAttemptAt = nil
        case .retryable(let kind):
            let attempt = (pending.retryCount ?? 0) + 1
            pending.retryCount = attempt
            pending.status = .retryableFailure
            pending.failureKind = kind
            pending.nextAttemptAt = now().addingTimeInterval(retryDelay(id: pending.id, attempt: attempt))
        case .permanent(let kind):
            pending.status = .permanentFailure
            pending.failureKind = kind
            pending.nextAttemptAt = nil
        }
        pending.errorMessage = message
    }

    private func failureDisposition(for error: Error) -> FailureDisposition {
        if error is CancellationError { return .cancelled }
        guard let apiError = error as? APIError else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return .retryable("transport") }
            return .retryable("unknown")
        }
        switch apiError {
        case .unauthorized, .forbidden, .tokenRefreshFailed:
            return .authentication
        case .networkError, .offlineQueued, .offlineQueueFull:
            return .retryable("transport")
        case .serverError(let statusCode, _):
            if statusCode == 408 || statusCode == 429 || statusCode >= 500 {
                return .retryable("http_\(statusCode)")
            }
            return .permanent("http_\(statusCode)")
        case .decodingError:
            // The server may already have committed. A stable document UUID
            // makes an idempotent retry safer than deleting the staged original.
            return .retryable("response_decoding")
        case .invalidURL:
            return .permanent("invalid_request")
        case .notFound:
            return .permanent("http_404")
        case .conflict:
            return .permanent("http_409")
        }
    }

    private func retryDelay(id: String, attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 6)
        let base = min(300.0, 5.0 * pow(2.0, Double(exponent)))
        let checksum = id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 21 }
        let jitter = 0.9 + Double(checksum) / 100.0
        return min(300.0, base * jitter)
    }

    private func reconcileOrphanUploadDirectories(
        uploads: [PendingDocumentUpload],
        expectedIdentityLease: IdentityLease
    ) async {
        guard isCurrent(expectedIdentityLease) else { return }
        let root: URL
        do {
            root = try uploadsDirectory()
        } catch {
            documentUploadLogger.error(
                "Orphan upload reconciliation could not open its protected root: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        let rootURL = root.standardizedFileURL
        var retained = Set<URL>()
        do {
            for upload in uploads {
                if let directory = try ownedUploadDirectory(for: upload) {
                    retained.insert(directory)
                }
            }
        } catch {
            // Never sweep potential user data when even one queue row cannot be
            // resolved conclusively against protected storage.
            documentUploadLogger.error(
                "Orphan upload reconciliation failed closed while resolving queue paths: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        retained.formUnion(
            stagingTasks.keys.map { rootURL.appendingPathComponent($0, isDirectory: true) }
        )
        let referenceDate = now()
        let minimumAge = orphanMinimumAge
        let maximumCandidates = orphanMaximumCandidates
        let maximumRemovals = orphanMaximumRemovals
        let runID = UUID()
        let task = Task.detached(priority: .utility) {
            Self.reconcileOrphanUploadDirectoriesOnDisk(
                at: rootURL,
                retaining: retained,
                fileManager: FileManager(),
                now: referenceDate,
                minimumAge: minimumAge,
                maximumCandidates: maximumCandidates,
                maximumRemovals: maximumRemovals
            )
        }
        orphanReconciliationRun = OrphanReconciliationRun(id: runID, task: task)
        _ = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if orphanReconciliationRun?.id == runID {
            orphanReconciliationRun = nil
        }
    }

    @discardableResult
    nonisolated private static func reconcileOrphanUploadDirectoriesOnDisk(
        at root: URL,
        retaining retained: Set<URL>,
        fileManager: FileManager,
        now: Date,
        minimumAge: TimeInterval,
        maximumCandidates: Int,
        maximumRemovals: Int
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
        guard
            let rootValues = try? standardizedRoot.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
            rootValues.isDirectory == true,
            rootValues.isSymbolicLink != true,
            let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in false }
            )
        else { return 0 }

        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        var removed = 0
        var inspectedCandidates = 0
        while !Task.isCancelled,
            removed < maximumRemovals,
            let entry = enumerator.nextObject() as? URL
        {
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == standardizedRoot,
                UUID(uuidString: candidate.lastPathComponent) != nil,
                !retained.contains(candidate),
                let directoryValues = try? candidate.resourceValues(forKeys: keys),
                directoryValues.isDirectory == true,
                directoryValues.isSymbolicLink != true,
                let directoryDate = directoryValues.contentModificationDate
                    ?? directoryValues.creationDate,
                directoryDate <= cutoff
            else { continue }
            guard
                uploadDirectoryHasAtMostOneStaleRegularFile(
                    candidate,
                    fileManager: fileManager,
                    keys: keys,
                    cutoff: cutoff
                )
            else { continue }
            guard inspectedCandidates < maximumCandidates else { break }
            inspectedCandidates += 1
            guard !Task.isCancelled else { break }
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    nonisolated private static func uploadDirectoryHasAtMostOneStaleRegularFile(
        _ directory: URL,
        fileManager: FileManager,
        keys: Set<URLResourceKey>,
        cutoff: Date
    ) -> Bool {
        var didEncounterError = false
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    didEncounterError = true
                    return false
                }
            )
        else { return false }
        guard let child = enumerator.nextObject() as? URL else {
            return !didEncounterError
        }
        let second = enumerator.nextObject()
        guard second == nil, !didEncounterError else { return false }
        let payload = child.standardizedFileURL
        guard payload.deletingLastPathComponent() == directory,
            let values = try? payload.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let date = values.contentModificationDate ?? values.creationDate
        else { return false }
        return date <= cutoff
    }
}
