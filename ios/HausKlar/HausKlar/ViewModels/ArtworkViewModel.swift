import Foundation
import UIKit

/// ViewModel for the kids' artwork archive: per-child gallery, capture uploads,
/// edits and deletes.
@MainActor
final class ArtworkViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var children: [ChildDTO] = []
    @Published var selectedChildId: String?
    @Published var artworks: [ArtworkDTO] = []
    @Published var thumbnails: [String: UIImage] = [:]  // artworkId -> thumb
    @Published var fullImages: [String: UIImage] = [:]  // artworkId -> full size
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var isLoadingMore = false
    @Published var hasMore = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published var recentlyDeleted: ArtworkDTO?

    // MARK: - Private

    private let apiClient = APIClient.shared
    private let imageCache = DecodedImageCache.shared

    /// Upload bounds: long edge ≤ 2048px, JPEG quality 0.8.
    nonisolated private static let maxUploadPixelSize: CGFloat = 4096
    nonisolated private static let uploadJPEGQuality: CGFloat = 0.9
    private static let pageSize = 40

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

    func loadArtworks(reset: Bool = true) async {
        guard let childId = selectedChildId else { return }
        if reset { isLoading = true } else { isLoadingMore = true }
        defer {
            isLoading = false
            isLoadingMore = false
        }
        do {
            let fetched: [ArtworkDTO] = try await apiClient.get(
                "/artworks/",
                queryItems: [
                    URLQueryItem(name: "child_id", value: childId),
                    URLQueryItem(name: "offset", value: String(reset ? 0 : artworks.count)),
                    URLQueryItem(name: "limit", value: String(Self.pageSize)),
                ]
            )
            if reset {
                artworks = fetched
                thumbnails.removeAll(keepingCapacity: true)
                fullImages.removeAll(keepingCapacity: true)
            } else {
                let known = Set(artworks.map(\.id))
                artworks.append(contentsOf: fetched.filter { !known.contains($0.id) })
            }
            hasMore = fetched.count == Self.pageSize
        } catch {
            if artworks.isEmpty {
                errorMessage = friendlyMessage(for: error, fallback: "Artwork could not be opened.".localized)
            }
        }
    }

    func loadMoreIfNeeded(after artwork: ArtworkDTO) async {
        guard hasMore, !isLoadingMore, artwork.id == artworks.last?.id else { return }
        await loadArtworks(reset: false)
    }

    func loadThumbnail(for artwork: ArtworkDTO) async {
        guard thumbnails[artwork.id] == nil,
            let lease = imageCache.currentLease()
        else { return }
        let expectedChildID = selectedChildId
        let client = apiClient
        let image = await imageCache.image(
            kind: .artworkThumbnail,
            resourceID: artwork.id,
            maximumPixelSize: 800,
            lease: lease
        ) {
            try await client.downloadData(
                "/artworks/\(artwork.id)/image",
                policy: .image(maximumBytes: 8 * 1_024 * 1_024),
                queryItems: [URLQueryItem(name: "size", value: "thumb")]
            )
        }
        guard !Task.isCancelled,
            selectedChildId == expectedChildID,
            artworks.contains(where: { $0.id == artwork.id }),
            let image
        else { return }
        thumbnails[artwork.id] = image
    }

    func releaseThumbnail(for artworkID: String) {
        thumbnails[artworkID] = nil
    }

    func loadFullImage(for artwork: ArtworkDTO) async {
        guard fullImages[artwork.id] == nil,
            let lease = imageCache.currentLease()
        else { return }
        let client = apiClient
        let image = await imageCache.image(
            kind: .artworkDisplay,
            resourceID: artwork.id,
            maximumPixelSize: 4_096,
            lease: lease
        ) {
            try await client.downloadData(
                "/artworks/\(artwork.id)/image",
                policy: .image(
                    maximumBytes: 75 * 1_024 * 1_024,
                    maximumDimension: 16_384,
                    maximumPixels: 100_000_000
                ),
                queryItems: [URLQueryItem(name: "size", value: "full")]
            )
        }
        guard !Task.isCancelled, let image else { return }
        fullImages = [artwork.id: image]
    }

    func releaseFullImage(for artworkID: String) {
        fullImages[artworkID] = nil
    }

    // MARK: - Mutations

    func upload(
        images: [UIImage],
        childId: String,
        approxDate: ApproxDate,
        title: String,
        notes: String,
        medium: String,
        story: String,
        childQuote: String,
        schoolYear: String,
        includeInYearbook: Bool
    ) async -> Int {
        guard !images.isEmpty else { return 0 }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        var savedCount = 0
        for (index, image) in images.enumerated() {
            do {
                let stagedFile = try await Task.detached(priority: .userInitiated) {
                    try Self.writeUploadJPEG(image)
                }.value
                let fileURL = stagedFile.fileURL

                var fields = ["child_id": childId, "approx_date": approxDate.apiValue]
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTitle.isEmpty {
                    fields["title"] = images.count == 1 ? trimmedTitle : "\(trimmedTitle) \(index + 1)"
                }
                let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedNotes.isEmpty { fields["notes"] = trimmedNotes }
                let extra = [
                    "medium": medium,
                    "story": story,
                    "child_quote": childQuote,
                    "school_year": schoolYear,
                ]
                for (key, value) in extra {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { fields[key] = trimmed }
                }
                fields["include_in_yearbook"] = includeInYearbook ? "true" : "false"

                let artwork: ArtworkDTO
                do {
                    artwork = try await apiClient.uploadMultipart(
                        "/artworks/",
                        fileURL: fileURL,
                        filename: "artwork.jpg",
                        mediaType: "image/jpeg",
                        fields: fields
                    )
                } catch {
                    await Task.detached(priority: .utility) {
                        PhotoUploadPrep.removeStagedFile(stagedFile)
                    }.value
                    throw error
                }
                await Task.detached(priority: .utility) {
                    PhotoUploadPrep.removeStagedFile(stagedFile)
                }.value
                if artwork.childId == selectedChildId {
                    artworks.insert(artwork, at: 0)
                }
                savedCount += 1
            } catch APIError.offlineQueued {
                savedCount += 1
            } catch {
                errorMessage = friendlyMessage(
                    for: error,
                    fallback: savedCount == 0
                        ? "The artwork could not be saved.".localized
                        : "\(savedCount) saved; one photo still needs attention."
                )
                break
            }
        }
        if savedCount > 0 { HapticManager.success() }
        else { HapticManager.error() }
        return savedCount
    }

    func update(
        _ artwork: ArtworkDTO,
        childId: String,
        approxDate: ApproxDate,
        title: String,
        notes: String,
        medium: String,
        story: String,
        childQuote: String,
        schoolYear: String,
        favourite: Bool,
        includeInYearbook: Bool
    ) async -> ArtworkDTO? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            func trimmed(_ value: String) -> String? {
                let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            }
            let updated: ArtworkDTO = try await apiClient.patch(
                "/artworks/\(artwork.id)",
                body: ArtworkUpdateRequest(
                    title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                    approxDate: approxDate.apiValue,
                    childId: childId,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    medium: trimmed(medium),
                    story: trimmed(story),
                    childQuote: trimmed(childQuote),
                    schoolYear: trimmed(schoolYear),
                    favourite: favourite,
                    includeInYearbook: includeInYearbook,
                    yearbookPosition: artwork.yearbookPosition
                )
            )
            if updated.childId == selectedChildId {
                if let index = artworks.firstIndex(where: { $0.id == updated.id }) {
                    artworks[index] = updated
                } else {
                    artworks.insert(updated, at: 0)
                }
            } else {
                artworks.removeAll { $0.id == updated.id }
            }
            HapticManager.success()
            return updated
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to update the artwork.".localized)
            HapticManager.error()
            return nil
        }
    }

    func delete(_ artwork: ArtworkDTO) async -> Bool {
        do {
            try await apiClient.delete("/artworks/\(artwork.id)")
            artworks.removeAll { $0.id == artwork.id }
            thumbnails[artwork.id] = nil
            fullImages[artwork.id] = nil
            imageCache.remove(kind: .artworkThumbnail, resourceID: artwork.id)
            imageCache.remove(kind: .artworkDisplay, resourceID: artwork.id)
            recentlyDeleted = artwork
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to delete the artwork.".localized)
            HapticManager.error()
            return false
        }
    }

    func undoDelete() async {
        guard let recentlyDeleted else { return }
        do {
            let restored: ArtworkDTO = try await apiClient.post(
                "/artworks/\(recentlyDeleted.id)/restore"
            )
            if restored.childId == selectedChildId {
                artworks.insert(restored, at: 0)
            }
            self.recentlyDeleted = nil
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The artwork could not be restored.")
        }
    }

    func setFavourite(_ artwork: ArtworkDTO, favourite: Bool) async -> ArtworkDTO? {
        await update(
            artwork,
            childId: artwork.childId,
            approxDate: ApproxDate(string: artwork.approxDate) ?? ApproxDate(year: Calendar.current.component(.year, from: Date())),
            title: artwork.title ?? "",
            notes: artwork.notes ?? "",
            medium: artwork.medium ?? "",
            story: artwork.story ?? "",
            childQuote: artwork.childQuote ?? "",
            schoolYear: artwork.schoolYear ?? "",
            favourite: favourite,
            includeInYearbook: artwork.includeInYearbook != false
        )
    }

    func setYearbookInclusion(_ artwork: ArtworkDTO, included: Bool) async -> ArtworkDTO? {
        await update(
            artwork,
            childId: artwork.childId,
            approxDate: ApproxDate(string: artwork.approxDate) ?? ApproxDate(year: Calendar.current.component(.year, from: Date())),
            title: artwork.title ?? "",
            notes: artwork.notes ?? "",
            medium: artwork.medium ?? "",
            story: artwork.story ?? "",
            childQuote: artwork.childQuote ?? "",
            schoolYear: artwork.schoolYear ?? "",
            favourite: artwork.favourite == true,
            includeInYearbook: included
        )
    }

    func updateAppearance(
        _ artwork: ArtworkDTO,
        rotationDegrees: Int,
        enhanced: Bool
    ) async -> ArtworkDTO? {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let updated: ArtworkDTO = try await apiClient.put(
                "/artworks/\(artwork.id)/appearance",
                body: ArtworkAppearanceRequest(
                    rotationDegrees: rotationDegrees,
                    enhanced: enhanced
                )
            )
            if let index = artworks.firstIndex(where: { $0.id == updated.id }) {
                artworks[index] = updated
            }
            thumbnails[updated.id] = nil
            fullImages[updated.id] = nil
            imageCache.remove(kind: .artworkThumbnail, resourceID: updated.id)
            imageCache.remove(kind: .artworkDisplay, resourceID: updated.id)
            await loadFullImage(for: updated)
            HapticManager.success()
            return updated
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "The photo could not be adjusted.")
            return nil
        }
    }

    func shareFile(for artwork: ArtworkDTO) async -> ShareExportItem? {
        await loadFullImage(for: artwork)
        guard !Task.isCancelled else { return nil }
        guard let image = fullImages[artwork.id] else {
            errorMessage = "The artwork could not be prepared for sharing."
            return nil
        }
        do {
            let lease = try await ShareExportStore.shared.currentLease()
            let filename = (artwork.title ?? "Artwork")
                .replacingOccurrences(of: "/", with: "-") + ".jpg"
            return try await ShareExportStore.shared.publishGeneratedFile(
                filename: filename,
                maximumBytes: PhotoUploadPrep.maximumOriginalBytes,
                lease: lease
            ) { destination in
                guard let data = Self.shareJPEGData(from: image),
                      data.count <= PhotoUploadPrep.maximumOriginalBytes else {
                    throw ShareExportStoreError.fileTooLarge
                }
                try data.write(
                    to: destination,
                    options: [.atomic, .completeFileProtection]
                )
            }
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Helpers

    private func friendlyMessage(for error: Error, fallback: String) -> String {
        return (error as? APIError)?.errorDescription ?? fallback
    }

    /// Downsamples to the upload bounds and re-encodes as JPEG.
    nonisolated static func downsampledJPEGData(from image: UIImage) -> Data? {
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let longEdge = max(pixelSize.width, pixelSize.height)
        var output = image
        if longEdge > maxUploadPixelSize, longEdge > 0 {
            let scale = maxUploadPixelSize / longEdge
            let target = CGSize(
                width: (pixelSize.width * scale).rounded(),
                height: (pixelSize.height * scale).rounded()
            )
            output = image.preparingThumbnail(of: target) ?? image
        }
        return output.jpegData(compressionQuality: uploadJPEGQuality)
    }

    nonisolated private static func shareJPEGData(from image: UIImage) -> Data? {
        guard !Task.isCancelled else { return nil }
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        let longEdge = max(pixelSize.width, pixelSize.height)
        let output: UIImage
        if longEdge > 4_096, longEdge > 0 {
            let scale = 4_096 / longEdge
            output = image.preparingThumbnail(
                of: CGSize(
                    width: (pixelSize.width * scale).rounded(),
                    height: (pixelSize.height * scale).rounded()
                )
            ) ?? image
        } else {
            output = image
        }
        guard !Task.isCancelled else { return nil }
        return output.jpegData(compressionQuality: 0.92)
    }

    nonisolated private static func writeUploadJPEG(
        _ image: UIImage
    ) throws -> PhotoUploadPrep.StagedFile {
        guard let data = downsampledJPEGData(from: image) else {
            throw DocumentCaptureError.unreadableFile
        }
        return try PhotoUploadPrep.stageGeneratedJPEG(data)
    }
}
