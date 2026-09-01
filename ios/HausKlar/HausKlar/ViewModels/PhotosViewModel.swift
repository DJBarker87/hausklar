import Foundation
import PhotosUI
import SwiftUI
import UIKit

/// ViewModel for the children's Photos gallery: a hand-picked, self-hosted archive
/// of photos per child. Batch uploads read each image's real capture date on-device
/// (EXIF) before posting the original bytes. Mirrors `ArtworkViewModel`, plus multi-select uploads
/// and camera-roll dates.
@MainActor
final class PhotosViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var children: [ChildDTO] = []
    @Published var selectedChildId: String?
    @Published var photos: [ChildPhotoDTO] = []
    @Published var thumbnails: [String: UIImage] = [:]  // photoId -> thumb
    @Published var fullImages: [String: UIImage] = [:]  // photoId -> full size
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var recentlyDeleted: ChildPhotoDTO?
    @Published var canLoadMore = false

    // Upload progress
    @Published var isUploading = false
    @Published var uploadPrepared = 0
    @Published var uploadTotal = 0

    // MARK: - Private

    private let apiClient = APIClient.shared
    private let imageCache = DecodedImageCache.shared

    private static let pageSize = 60

    struct MomentDetails {
        let caption: String
        let location: String
        let story: String
        let includeInYearbook: Bool

        static let empty = MomentDetails(
            caption: "", location: "", story: "", includeInYearbook: true
        )
    }

    private struct SkippedPhotos {
        var oversized = 0
        var unsafe = 0
        var unsupported = 0
        var unreadable = 0

        var total: Int { oversized + unsafe + unsupported + unreadable }

        mutating func record(_ error: Error) {
            switch Self.preparationError(in: error) {
            case .fileTooLarge:
                oversized += 1
            case .unsafeDimensions:
                unsafe += 1
            case .unsupportedImage, .declaredTypeMismatch:
                unsupported += 1
            default:
                unreadable += 1
            }
        }

        private static func preparationError(in error: Error) -> PhotoUploadPrepError? {
            if let error = error as? PhotoUploadPrepError { return error }
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
            guard let underlying, (underlying as NSError) !== (error as NSError) else { return nil }
            return preparationError(in: underlying)
        }

        var message: String? {
            guard total > 0 else { return nil }
            var reasons: [String] = []
            if oversized > 0 { reasons.append("\(oversized) over 25 MB") }
            if unsafe > 0 { reasons.append("\(unsafe) with unsafe dimensions") }
            if unsupported > 0 { reasons.append("\(unsupported) unsupported or mismatched") }
            if unreadable > 0 { reasons.append("\(unreadable) unreadable") }
            return "Skipped \(total) selected photo\(total == 1 ? "" : "s") (\(reasons.joined(separator: ", ")))."
        }
    }

    var selectedChildName: String {
        children.first { $0.id == selectedChildId }?.name ?? "your child"
    }

    // MARK: - Loading

    func loadChildren() async {
        do {
            let fetched: [ChildDTO] = try await apiClient.get("/children/")
            children = fetched
            if selectedChildId == nil {
                selectedChildId = fetched.first?.id
            }
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load children.".localized)
        }
    }

    func loadPhotos(reset: Bool = true) async {
        guard let childId = selectedChildId else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched: [ChildPhotoDTO] = try await apiClient.get(
                "/child-photos/",
                queryItems: [
                    URLQueryItem(name: "child_id", value: childId),
                    URLQueryItem(name: "offset", value: reset ? "0" : String(photos.count)),
                    URLQueryItem(name: "limit", value: String(Self.pageSize)),
                ]
            )
            if reset {
                photos = fetched
                thumbnails.removeAll(keepingCapacity: true)
                fullImages.removeAll(keepingCapacity: true)
            } else {
                let existing = Set(photos.map(\.id))
                photos.append(contentsOf: fetched.filter { !existing.contains($0.id) })
            }
            canLoadMore = fetched.count == Self.pageSize
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load photos.".localized)
        }
    }

    func loadMoreIfNeeded(after photo: ChildPhotoDTO) async {
        guard canLoadMore, !isLoading else { return }
        let threshold = photos.index(photos.endIndex, offsetBy: -min(8, photos.count))
        guard let index = photos.firstIndex(where: { $0.id == photo.id }), index >= threshold else { return }
        await loadPhotos(reset: false)
    }

    func loadThumbnail(for photo: ChildPhotoDTO) async {
        guard thumbnails[photo.id] == nil,
            let lease = imageCache.currentLease()
        else { return }
        let expectedChildID = selectedChildId
        let client = apiClient
        let image = await imageCache.image(
            kind: .childPhotoThumbnail,
            resourceID: photo.id,
            maximumPixelSize: 800,
            lease: lease
        ) {
            try await client.downloadData(
                "/child-photos/\(photo.id)/image",
                policy: .image(maximumBytes: 5 * 1_024 * 1_024),
                queryItems: [URLQueryItem(name: "size", value: "thumb")]
            )
        }
        guard !Task.isCancelled,
            selectedChildId == expectedChildID,
            photos.contains(where: { $0.id == photo.id }),
            let image
        else { return }
        thumbnails[photo.id] = image
    }

    func releaseThumbnail(for photoID: String) {
        thumbnails[photoID] = nil
    }

    func loadFullImage(for photo: ChildPhotoDTO) async {
        guard fullImages[photo.id] == nil,
            let lease = imageCache.currentLease()
        else { return }
        let client = apiClient
        let image = await imageCache.image(
            kind: .childPhotoDisplay,
            resourceID: photo.id,
            maximumPixelSize: 4_096,
            lease: lease
        ) {
            try await client.downloadData(
                "/child-photos/\(photo.id)/image",
                policy: .image(maximumBytes: PhotoUploadPrep.maximumOriginalBytes),
                queryItems: [URLQueryItem(name: "size", value: "display")]
            )
        }
        guard !Task.isCancelled, let image else { return }
        fullImages = [photo.id: image]
    }

    func releaseFullImage(for photoID: String) {
        fullImages[photoID] = nil
    }

    // MARK: - Batch upload

    /// Stages and validates at most one upload batch at a time. Photos' provider
    /// files remain untouched; every owned staging directory is erased as soon as
    /// its request has either been acknowledged or durably queued.
    func addPhotos(
        from items: [PhotosPickerItem],
        childId: String,
        details: MomentDetails = .empty
    ) async {
        guard !items.isEmpty else { return }
        guard !isUploading else {
            infoMessage = "Your current photo upload is still in progress.".localized
            return
        }
        isUploading = true
        errorMessage = nil
        infoMessage = nil
        uploadTotal = items.count
        uploadPrepared = 0
        defer {
            isUploading = false
            uploadTotal = 0
            uploadPrepared = 0
        }
        var batch: [PhotoUploadPrep.PreparedFile] = []
        var batchBytes = 0
        var acceptedCount = 0
        var sentBatchCount = 0
        var queuedCount = 0
        var skipped = SkippedPhotos()
        var terminalError: Error?
        var wasCancelled = false
        defer {
            for file in batch {
                PhotoUploadPrep.removeStagedFile(file.stagedFile)
            }
        }

        func sendCurrentBatch() async -> Bool {
            guard !batch.isEmpty else { return true }
            let sending = batch
            batch.removeAll(keepingCapacity: true)
            batchBytes = 0
            sentBatchCount += 1
            do {
                _ = try await uploadChunk(sending, childId: childId, details: details)
                for file in sending {
                    PhotoUploadPrep.removeStagedFile(file.stagedFile)
                }
                return true
            } catch APIError.offlineQueued {
                queuedCount += sending.count
                for file in sending {
                    PhotoUploadPrep.removeStagedFile(file.stagedFile)
                }
                return true
            } catch {
                for file in sending {
                    PhotoUploadPrep.removeStagedFile(file.stagedFile)
                }
                if Task.isCancelled {
                    wasCancelled = true
                } else {
                    terminalError = error
                }
                return false
            }
        }

        for item in items {
            if Task.isCancelled {
                wasCancelled = true
                break
            }
            var stagedFile: PhotoUploadPrep.StagedFile?
            do {
                let declaredTypes = item.supportedContentTypes.map(\.identifier)
                guard let transfer = try await item.loadTransferable(
                    type: StagedPhotoTransfer.self
                ) else {
                    skipped.unreadable += 1
                    uploadPrepared += 1
                    continue
                }
                let ownedStagedFile = try transfer.takeStagedFile()
                stagedFile = ownedStagedFile
                let preparation = Task.detached(priority: .userInitiated) {
                    try PhotoUploadPrep.prepareStagedFile(
                        ownedStagedFile,
                        declaredTypeIdentifiers: declaredTypes,
                        childId: childId
                    )
                }
                let prepared = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                stagedFile = nil // Ownership moves into `prepared` and then `batch`.

                if PhotoUploadPrep.shouldStartNewBatch(
                    currentFileCount: batch.count,
                    currentBytes: batchBytes,
                    nextFileBytes: prepared.byteCount
                ), !(await sendCurrentBatch()) {
                    PhotoUploadPrep.removeStagedFile(prepared.stagedFile)
                    uploadPrepared += 1
                    break
                }
                batch.append(prepared)
                batchBytes += prepared.byteCount
                acceptedCount += 1
                uploadPrepared += 1

                if batch.count == PhotoUploadPrep.maximumFilesPerBatch
                    || batchBytes == PhotoUploadPrep.maximumBatchFileBytes {
                    guard await sendCurrentBatch() else { break }
                }
            } catch {
                if let stagedFile { PhotoUploadPrep.removeStagedFile(stagedFile) }
                uploadPrepared += 1
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }
                skipped.record(error)
            }
        }

        if !wasCancelled, terminalError == nil {
            _ = await sendCurrentBatch()
        }

        if wasCancelled {
            infoMessage = "Photo upload cancelled."
            return
        }
        if let terminalError {
            errorMessage = friendlyMessage(
                for: terminalError,
                fallback: "Failed to upload photos.".localized
            )
        } else if acceptedCount == 0 {
            errorMessage = skipped.message ?? "None of the selected photos could be read.".localized
        }

        if terminalError == nil, acceptedCount > 0, childId == selectedChildId {
            await loadPhotos()
        }

        var notices: [String] = []
        if let skippedMessage = skipped.message { notices.append(skippedMessage) }
        if queuedCount > 0 {
            notices.append(
                "\(queuedCount) photo\(queuedCount == 1 ? "" : "s") saved offline and waiting to sync."
            )
        } else if sentBatchCount > 1, terminalError == nil {
            notices.append("Saved \(acceptedCount) photos in \(sentBatchCount) bounded batches.")
        }
        infoMessage = notices.isEmpty ? nil : notices.joined(separator: " ")

        if terminalError != nil || acceptedCount == 0 {
            HapticManager.error()
        } else {
            HapticManager.success()
        }
    }

    private func uploadChunk(
        _ chunk: [PhotoUploadPrep.PreparedFile],
        childId: String,
        details: MomentDetails
    ) async throws -> [ChildPhotoDTO] {
        var orderedFields: [(name: String, value: String)] = [("child_id", childId)]
        let caption = details.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = details.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let story = details.story.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty { orderedFields.append(("caption", caption)) }
        if !location.isEmpty { orderedFields.append(("location", location)) }
        if !story.isEmpty { orderedFields.append(("story", story)) }
        orderedFields.append(("include_in_yearbook", details.includeInYearbook ? "true" : "false"))
        var files: [(filename: String, mediaType: String, fileURL: URL)] = []
        for photo in chunk {
            // `taken_on` repeats once per file, in the same order as `files`.
            orderedFields.append(("taken_on", photo.takenOn))
            orderedFields.append(("client_id", photo.clientId))
            files.append((photo.filename, photo.mediaType, photo.fileURL))
        }
        let response: ChildPhotoUploadResponse = try await apiClient.uploadMultipartFiles(
            "/child-photos/",
            fileFieldName: "files",
            files: files,
            orderedFields: orderedFields
        )
        return response.photos
    }

    // MARK: - Mutations

    func update(
        _ photo: ChildPhotoDTO,
        caption: String,
        takenOn: String,
        childId: String,
        location: String,
        story: String,
        favourite: Bool,
        includeInYearbook: Bool
    ) async -> ChildPhotoDTO? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated: ChildPhotoDTO = try await apiClient.patch(
                "/child-photos/\(photo.id)",
                body: ChildPhotoUpdateRequest(
                    caption: trimmed.isEmpty ? nil : trimmed,
                    takenOn: takenOn,
                    childId: childId,
                    location: location.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    story: story.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    favourite: favourite,
                    includeInYearbook: includeInYearbook
                )
            )
            if updated.childId == selectedChildId {
                if let index = photos.firstIndex(where: { $0.id == updated.id }) {
                    photos[index] = updated
                } else {
                    photos.insert(updated, at: 0)
                }
                // Carry the cached imagery across to the (possibly re-homed) record.
                if let thumb = thumbnails[photo.id] { thumbnails[updated.id] = thumb }
                if let full = fullImages[photo.id] { fullImages[updated.id] = full }
            } else {
                // Moved to a different child — drop it from this gallery.
                photos.removeAll { $0.id == updated.id }
            }
            HapticManager.success()
            return updated
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to update the photo.".localized)
            HapticManager.error()
            return nil
        }
    }

    func delete(_ photo: ChildPhotoDTO) async -> Bool {
        do {
            try await apiClient.delete("/child-photos/\(photo.id)")
            photos.removeAll { $0.id == photo.id }
            thumbnails[photo.id] = nil
            fullImages[photo.id] = nil
            imageCache.remove(kind: .childPhotoThumbnail, resourceID: photo.id)
            imageCache.remove(kind: .childPhotoDisplay, resourceID: photo.id)
            recentlyDeleted = photo
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to delete the photo.".localized)
            HapticManager.error()
            return false
        }
    }

    func undoDelete() async {
        guard let removed = recentlyDeleted else { return }
        do {
            let restored: ChildPhotoDTO = try await apiClient.post(
                "/child-photos/\(removed.id)/restore"
            )
            if restored.childId == selectedChildId { photos.insert(restored, at: 0) }
            recentlyDeleted = nil
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The photo could not be restored.")
            HapticManager.error()
        }
    }

    func setFavourite(_ photo: ChildPhotoDTO, favourite: Bool) async -> ChildPhotoDTO? {
        await update(
            photo,
            caption: photo.caption ?? "",
            takenOn: photo.takenOn,
            childId: photo.childId,
            location: photo.location ?? "",
            story: photo.story ?? "",
            favourite: favourite,
            includeInYearbook: photo.includeInYearbook != false
        )
    }

    func setYearbookInclusion(_ photo: ChildPhotoDTO, included: Bool) async -> ChildPhotoDTO? {
        await update(
            photo,
            caption: photo.caption ?? "",
            takenOn: photo.takenOn,
            childId: photo.childId,
            location: photo.location ?? "",
            story: photo.story ?? "",
            favourite: photo.favourite == true,
            includeInYearbook: included
        )
    }

    func shareFile(for photo: ChildPhotoDTO) async -> ShareExportItem? {
        do {
            let lease = try await ShareExportStore.shared.currentLease()
            let imageSize = photo.originalAvailable == true ? "original" : "display"
            let temporaryFile = try await apiClient.downloadToTemporaryFile(
                "/child-photos/\(photo.id)/image",
                filename: "\(photo.id)-original",
                maximumBytes: PhotoUploadPrep.maximumOriginalBytes,
                allowedMediaTypes: PhotoUploadPrep.acceptedUploadTypes,
                queryItems: [URLQueryItem(name: "size", value: imageSize)]
            )
            do {
                guard let metadata = await Task.detached(
                    priority: .userInitiated,
                    operation: {
                        PhotoUploadPrep.fileMetadata(at: temporaryFile)
                    }
                ).value else {
                    throw PhotoUploadPrepError.unsupportedImage
                }
                try Task.checkCancellation()
                let safeBase = (photo.caption ?? "\(photo.childDisplayName) \(photo.takenOn)")
                    .replacingOccurrences(of: "/", with: "-")
                let filename = APIClient.safeDownloadFilename(
                    "\(safeBase).\(metadata.fileExtension)"
                )
                let item = try await ShareExportStore.shared.adoptDownloadedFile(
                    temporaryFile,
                    filename: filename,
                    maximumBytes: PhotoUploadPrep.maximumOriginalBytes,
                    lease: lease
                )
                await apiClient.releaseTemporaryDownload(temporaryFile)
                return item
            } catch {
                await apiClient.releaseTemporaryDownload(temporaryFile)
                throw error
            }
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = friendlyMessage(
                for: error,
                fallback: error.localizedDescription
            )
            return nil
        }
    }

    // MARK: - Helpers

    private func friendlyMessage(for error: Error, fallback: String) -> String {
        return (error as? APIError)?.errorDescription ?? fallback
    }

}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
