import Foundation
import UIKit

/// ViewModel for semantic photo search ("Bismarck recall"). Fetches result
/// metadata, then lazily downloads authenticated thumbnails for the grid.
@MainActor
final class PhotoSearchViewModel: ObservableObject {

    @Published var query = ""
    @Published var results: [PhotoSearchResultDTO] = []
    @Published var thumbnails: [String: UIImage] = [:]  // assetId -> thumbnail
    @Published var isSearching = false
    @Published var hasSearched = false
    @Published var errorMessage: String?

    private let apiClient = APIClient.shared
    private let imageCache = DecodedImageCache.shared
    private var searchTask: Task<Void, Never>?

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            thumbnails.removeAll(keepingCapacity: true)
            hasSearched = false
            return
        }

        // Supersede any in-flight search so only the latest query wins.
        searchTask?.cancel()
        let task = Task { await performSearch(trimmed) }
        searchTask = task
        await task.value
    }

    private func performSearch(_ trimmed: String) async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let response: PhotoSearchResponseDTO = try await apiClient.get(
                "/photos/search",
                queryItems: [
                    URLQueryItem(name: "q", value: trimmed),
                    URLQueryItem(name: "limit", value: "30"),
                ],
                bypassCache: true
            )
            guard !Task.isCancelled else { return }
            results = response.results
            thumbnails.removeAll(keepingCapacity: true)
            hasSearched = true
        } catch is CancellationError {
            // Superseded by a newer search; ignore.
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            hasSearched = true
            errorMessage = friendlyMessage(for: error)
        }
    }

    func loadThumbnail(for result: PhotoSearchResultDTO) async {
        guard thumbnails[result.assetId] == nil,
            let lease = imageCache.currentLease()
        else { return }
        let client = apiClient
        let image = await imageCache.image(
            kind: .photoArchiveThumbnail,
            resourceID: result.assetId,
            maximumPixelSize: 800,
            lease: lease
        ) {
            try await client.downloadData(
                "/photos/\(result.assetId)/thumbnail",
                policy: .image(maximumBytes: 8 * 1_024 * 1_024),
                queryItems: [URLQueryItem(name: "size", value: "preview")]
            )
        }
        guard !Task.isCancelled,
            results.contains(where: { $0.assetId == result.assetId }),
            let image
        else { return }
        thumbnails[result.assetId] = image
    }

    func releaseThumbnail(for assetID: String) {
        thumbnails[assetID] = nil
    }

    func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        thumbnails.removeAll(keepingCapacity: true)
        hasSearched = false
        errorMessage = nil
    }

    private func friendlyMessage(for error: Error) -> String {
        if case APIError.networkError = error {
            return "You appear to be offline. Photo search needs a connection.".localized
        }
        return (error as? APIError)?.errorDescription ?? "Photo search is unavailable right now.".localized
    }
}
