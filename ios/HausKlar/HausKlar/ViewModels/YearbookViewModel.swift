import Foundation
import UIKit

/// A task-group result bridge for an image created and consumed exclusively on
/// `MainActor`. The wrapper never authorizes off-main UIImage access.
private struct YearbookSendableImage: @unchecked Sendable {
    let value: UIImage
}

/// ViewModel for the Yearbook: a per-child, per-year keepsake. Loads the available
/// years for a child, the yearbook itself, and the authenticated artwork/photo
/// thumbnails. Online-only — offline surfaces a friendly message. Any section may be
/// empty; the view handles a sparse or quiet year gracefully.
@MainActor
final class YearbookViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var children: [ChildDTO] = []
    @Published var selectedChildId: String?
    @Published var years: [Int] = []
    @Published var selectedYear: Int = Calendar.current.component(.year, from: Date())
    @Published var yearbook: YearbookDTO?
    @Published var images: [String: UIImage] = [:]  // artwork id / photo asset id -> thumbnail
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var refreshNote: String?
    @Published var options: YearbookOptionsDTO?
    @Published var artworkOrder: [String] = []
    @Published var photoOrder: [String] = []
    @Published var isBuilderLoading = false
    @Published var isBuilderSaving = false
    @Published var builderError: String?

    // MARK: - Private

    private let apiClient = APIClient.shared
    private let imageCache = DecodedImageCache.shared
    private var imageConsumers: [String: Int] = [:]

    init(initialChildId: String? = nil) {
        selectedChildId = initialChildId
    }

    var selectedChildName: String {
        children.first { $0.id == selectedChildId }?.name ?? "your child"
    }

    // MARK: - Loading

    func loadChildren() async {
        do {
            let fetched: [ChildDTO] = try await apiClient.get("/children/")
            children = fetched
            if selectedChildId == nil || !fetched.contains(where: { $0.id == selectedChildId }) {
                selectedChildId = fetched.first?.id
            }
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load children.".localized)
        }
    }

    /// Loads the available years for the selected child and picks a sensible default.
    func loadYears() async {
        guard let childId = selectedChildId else { return }
        do {
            let response: YearbookYearsDTO = try await apiClient.get("/yearbook/\(childId)/years")
            let list = response.years.isEmpty ? [Calendar.current.component(.year, from: Date())] : response.years
            years = list
            if !list.contains(selectedYear) {
                selectedYear = list.first ?? selectedYear
            }
        } catch {
            years = [Calendar.current.component(.year, from: Date())]
        }
    }

    func loadYearbook() async {
        guard let childId = selectedChildId else { return }
        yearbook = nil
        releaseAllImages()
        isLoading = true
        errorMessage = nil
        refreshNote = nil
        defer { isLoading = false }
        do {
            let fetched: YearbookDTO = try await apiClient.get("/yearbook/\(childId)/\(selectedYear)")
            yearbook = fetched
        } catch {
            yearbook = nil
            errorMessage = friendlyMessage(for: error, fallback: "This yearbook could not be opened.".localized)
        }
    }

    /// Loads every candidate without changing the current keepsake. Selection and
    /// order remain local until the parent reaches Preview and confirms them.
    func loadOptions() async {
        guard let childId = selectedChildId else { return }
        isBuilderLoading = true
        builderError = nil
        defer { isBuilderLoading = false }
        do {
            let fetched: YearbookOptionsDTO = try await apiClient.get(
                "/yearbook/\(childId)/\(selectedYear)/options"
            )
            options = fetched
            artworkOrder = fetched.artwork
                .filter(\.includeInYearbook)
                .sorted { ($0.yearbookPosition ?? Int.max) < ($1.yearbookPosition ?? Int.max) }
                .map(\.id)
            photoOrder = fetched.photos
                .filter(\.includeInYearbook)
                .sorted { ($0.yearbookPosition ?? Int.max) < ($1.yearbookPosition ?? Int.max) }
                .map(\.id)
        } catch {
            options = nil
            builderError = friendlyMessage(
                for: error,
                fallback: "The Yearbook choices could not be opened."
            )
        }
    }

    func toggleArtwork(_ id: String) {
        if let index = artworkOrder.firstIndex(of: id) {
            artworkOrder.remove(at: index)
        } else {
            artworkOrder.append(id)
        }
        HapticManager.selection()
    }

    func togglePhoto(_ id: String) {
        if let index = photoOrder.firstIndex(of: id) {
            photoOrder.remove(at: index)
        } else {
            photoOrder.append(id)
        }
        HapticManager.selection()
    }

    func moveArtwork(_ id: String, by offset: Int) {
        let moved = Self.moved(id, by: offset, within: artworkOrder)
        guard moved != artworkOrder else { return }
        artworkOrder = moved
        HapticManager.selection()
    }

    func movePhoto(_ id: String, by offset: Int) {
        let moved = Self.moved(id, by: offset, within: photoOrder)
        guard moved != photoOrder else { return }
        photoOrder = moved
        HapticManager.selection()
    }

    func artworkCandidate(_ id: String) -> YearbookOptionsDTO.ArtworkCandidate? {
        options?.artwork.first { $0.id == id }
    }

    func photoCandidate(_ id: String) -> YearbookOptionsDTO.PhotoCandidate? {
        options?.photos.first { $0.id == id }
    }

    /// Saves the exact selection and ordering in one request, then replaces the
    /// visible yearbook with the server-composed result.
    func saveArrangement() async -> Bool {
        guard let childId = selectedChildId else { return false }
        isBuilderSaving = true
        builderError = nil
        defer { isBuilderSaving = false }
        do {
            let fetched: YearbookDTO = try await apiClient.put(
                "/yearbook/\(childId)/\(selectedYear)/arrangement",
                body: YearbookArrangementRequest(
                    artworkIds: artworkOrder,
                    photoIds: photoOrder
                )
            )
            yearbook = fetched
            HapticManager.success()
            return true
        } catch {
            builderError = friendlyMessage(
                for: error,
                fallback: "Those Yearbook choices could not be saved."
            )
            HapticManager.error()
            return false
        }
    }

    func loadArtworkImage(id: String) async {
        await loadVisibleImage(id: id, kind: .artworkThumbnail)
    }

    func loadPhotoImage(id: String) async {
        await loadVisibleImage(id: id, kind: .childPhotoThumbnail)
    }

    func releaseImage(id: String) {
        let remaining = max(0, (imageConsumers[id] ?? 0) - 1)
        if remaining == 0 {
            imageConsumers[id] = nil
            images[id] = nil
        } else {
            imageConsumers[id] = remaining
        }
    }

    func releaseAllImages() {
        imageConsumers.removeAll(keepingCapacity: false)
        images.removeAll(keepingCapacity: false)
    }

    /// Called when the child changes: refresh the year list, then the yearbook.
    func childChanged() async {
        yearbook = nil
        releaseAllImages()
        await loadYears()
        await loadYearbook()
    }

    /// Regenerates the AI narrative (rate-limited server-side to 10/hour).
    func refreshNarrative() async {
        guard let childId = selectedChildId, !isRefreshing else { return }
        isRefreshing = true
        refreshNote = nil
        defer { isRefreshing = false }
        do {
            let fetched: YearbookDTO = try await apiClient.post(
                "/yearbook/\(childId)/\(selectedYear)/refresh",
                body: EmptyBody()
            )
            yearbook = fetched
            HapticManager.success()
        } catch APIError.serverError(let statusCode, _) where statusCode == 429 {
            refreshNote = "The story was refreshed a few times just now — please try again a little later.".localized
        } catch APIError.serverError(let statusCode, _) where statusCode == 428 {
            refreshNote = "Allow OpenAI in Settings → AI & Family Data before writing this story.".localized
        } catch {
            refreshNote = friendlyMessage(for: error, fallback: "The story could not be rewritten just now.".localized)
        }
    }

    /// PDF generation uses the shared cache directly and never publishes its
    /// temporary working set into the scrolling view's visible-image dictionary.
    func exportImages(for book: YearbookDTO) async -> [String: UIImage] {
        guard let lease = imageCache.currentLease() else { return [:] }
        let requests =
            book.sections.artwork.items.map {
                ($0.id, DecodedImageCacheKey.Kind.artworkThumbnail)
            }
            + book.sections.photos.highlights.map {
                ($0.assetId, DecodedImageCacheKey.Kind.childPhotoThumbnail)
            }
        return await withTaskGroup(
            of: (String, YearbookSendableImage?).self,
            returning: [String: UIImage].self
        ) { group in
            for request in requests {
                group.addTask { @MainActor @Sendable [weak self] in
                    guard let self else { return (request.0, nil) }
                    let image = await self.cachedImage(
                        id: request.0,
                        kind: request.1,
                        lease: lease
                    )
                    return (request.0, image.map(YearbookSendableImage.init(value:)))
                }
            }
            var result: [String: UIImage] = [:]
            for await (id, image) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let image { result[id] = image.value }
            }
            return result
        }
    }

    private func loadVisibleImage(
        id: String,
        kind: DecodedImageCacheKey.Kind
    ) async {
        imageConsumers[id, default: 0] += 1
        guard images[id] == nil,
            let lease = imageCache.currentLease()
        else { return }
        let image = await cachedImage(id: id, kind: kind, lease: lease)
        guard !Task.isCancelled,
            (imageConsumers[id] ?? 0) > 0,
            let image
        else { return }
        images[id] = image
    }

    private func cachedImage(
        id: String,
        kind: DecodedImageCacheKey.Kind,
        lease: DecodedImageCacheLease
    ) async -> UIImage? {
        let client = apiClient
        switch kind {
        case .artworkThumbnail:
            return await imageCache.image(
                kind: kind,
                resourceID: id,
                maximumPixelSize: 800,
                lease: lease
            ) {
                try await client.downloadData(
                    "/artworks/\(id)/image",
                    policy: .image(maximumBytes: 8 * 1_024 * 1_024),
                    queryItems: [URLQueryItem(name: "size", value: "thumb")]
                )
            }
        case .childPhotoThumbnail:
            return await imageCache.image(
                kind: kind,
                resourceID: id,
                maximumPixelSize: 800,
                lease: lease
            ) {
                try await client.downloadData(
                    "/child-photos/\(id)/image",
                    policy: .image(maximumBytes: 8 * 1_024 * 1_024),
                    queryItems: [URLQueryItem(name: "size", value: "thumb")]
                )
            }
        case .artworkDisplay, .childPhotoDisplay, .photoArchiveThumbnail:
            return nil
        }
    }

    nonisolated private static func moved(
        _ id: String, by offset: Int, within order: [String]
    ) -> [String] {
        var order = order
        guard let index = order.firstIndex(of: id) else { return order }
        let destination = min(max(index + offset, 0), order.count - 1)
        guard destination != index else { return order }
        order.swapAt(index, destination)
        return order
    }

    // MARK: - Helpers

    private func friendlyMessage(for error: Error, fallback: String) -> String {
        if case APIError.networkError = error {
            return "You appear to be offline. The Yearbook needs a connection.".localized
        }
        return (error as? APIError)?.errorDescription ?? fallback
    }
}
