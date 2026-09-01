import Combine
import Foundation
import ImageIO
import UIKit

/// Loads only opaque Home media artwork routes through HausKlar's authenticated
/// transport, then retains bounded downsampled images for the current owner.
@MainActor
final class HomeMediaThumbnailService {
    static let shared = HomeMediaThumbnailService()

    nonisolated static let maximumDownloadBytes = 3 * 1_024 * 1_024
    nonisolated static let maximumSourceDimension: Int64 = 8_192
    nonisolated static let maximumSourcePixels: Int64 = 24_000_000
    nonisolated static let maximumRenderedPixelSize = 512

    typealias DataLoader = (
        APIRequestPath,
        APIClient.DownloadDataPolicy
    ) async throws -> Data

    private let dataLoader: DataLoader
    private let ownerIdentity: () -> String?
    private let imageCache = NSCache<NSString, UIImage>()
    private var activeOwner: String?
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(
        dataLoader: @escaping DataLoader = { path, policy in
            try await APIClient.shared.downloadData(
                path,
                policy: policy,
                cachePolicy: .networkOnly
            )
        },
        ownerIdentity: @escaping () -> String? = { APIClient.shared.cacheIdentity }
    ) {
        self.dataLoader = dataLoader
        self.ownerIdentity = ownerIdentity
        imageCache.countLimit = 96
        imageCache.totalCostLimit = 16 * 1_024 * 1_024
        imageCache.evictsObjectsWithDiscardedContent = true
    }

    func image(
        for path: APIRequestPath,
        maximumPixelSize: Int = 160
    ) async -> UIImage? {
        guard let owner = ownerIdentity(), !owner.isEmpty else {
            clear()
            return nil
        }
        guard let rawPath = try? path.validatedValue(),
            SpotifyBrowseViewModel.isThumbnailProxyPath(rawPath)
        else {
            return nil
        }
        activate(owner: owner)
        let pixelSize = min(max(maximumPixelSize, 32), Self.maximumRenderedPixelSize)
        let key = "\(owner)|\(rawPath)|\(pixelSize)"
        if let cached = imageCache.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            let image = await task.value
            return ownerIdentity() == owner ? image : nil
        }

        let policy = APIClient.DownloadDataPolicy.image(
            maximumBytes: Self.maximumDownloadBytes,
            maximumDimension: Int(Self.maximumSourceDimension),
            maximumPixels: Self.maximumSourcePixels
        )
        let task = Task { [dataLoader] in
            do {
                let data = try await dataLoader(path, policy)
                try Task.checkCancellation()
                return await Task.detached(priority: .utility) {
                    Self.downsample(data, maximumPixelSize: pixelSize)
                }.value
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight.removeValue(forKey: key)
        guard !Task.isCancelled,
            ownerIdentity() == owner,
            let image
        else { return nil }
        let cost = min(
            image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0,
            imageCache.totalCostLimit
        )
        imageCache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    func clear() {
        activeOwner = nil
        imageCache.removeAllObjects()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    private func activate(owner: String) {
        guard activeOwner != owner else { return }
        clear()
        activeOwner = owner
    }

    nonisolated static func safeSourceDimensions(width: Int64, height: Int64) -> Bool {
        guard width > 0,
            height > 0,
            width <= maximumSourceDimension,
            height <= maximumSourceDimension,
            width <= Int64.max / height
        else { return false }
        return width * height <= maximumSourcePixels
    }

    nonisolated static func downsample(
        _ data: Data,
        maximumPixelSize: Int
    ) -> UIImage? {
        guard !data.isEmpty,
            data.count <= maximumDownloadBytes,
            (32...maximumRenderedPixelSize).contains(maximumPixelSize),
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetCount(source) == 1,
            let sourceType = CGImageSourceGetType(source) as String?,
            Set(["public.jpeg", "public.png", "org.webmproject.webp"])
                .contains(sourceType.lowercased()),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
            safeSourceDimensions(width: width, height: height),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            ),
            thumbnail.width <= maximumPixelSize,
            thumbnail.height <= maximumPixelSize
        else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}

/// View model for Spotify search and browse, extracted from HomeViewModel.
/// Handles SpotifyPlus search, artist/album/playlist browsing, and HA media browsing.
@MainActor
final class SpotifyBrowseViewModel: ObservableObject {

    // MARK: - Published State

    @Published var errorMessage: String?

    let haClient: HAClient

    init(haClient: HAClient) {
        self.haClient = haClient
    }

    // MARK: - Data Structures

    struct BrowseItem: Identifiable {
        let id = UUID()
        let title: String
        let mediaContentType: String
        let mediaContentId: String
        let canPlay: Bool
        let canExpand: Bool
        let thumbnailPath: APIRequestPath?
    }

    struct BrowseResult {
        let title: String
        let children: [BrowseItem]
    }

    // MARK: - Spotify Entity

    private static let spotifyPlusEntityId = "media_player.example_0f8d3b93"

    // MARK: - Spotify Search

    /// Search Spotify via SpotifyPlus. Returns parsed BrowseItems.
    func searchSpotify(query: String, category: String) async -> [BrowseItem] {
        let serviceMap = [
            "track": "search_tracks",
            "artist": "search_artists",
            "playlist": "search_playlists",
        ]
        guard let service = serviceMap[category] else { return [] }

        do {
            let response = try await haClient.callServiceWithResponse(
                domain: "spotifyplus",
                service: service,
                data: [
                    "entity_id": Self.spotifyPlusEntityId,
                    "criteria": query,
                    "limit_total": 20,
                ]
            )
            return parseSpotifySearchResponse(response, category: category)
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    /// Browse into a Spotify URI (artist -> albums, playlist -> tracks, album -> tracks).
    func browseMedia(contentId: String, contentType: String) async -> BrowseResult? {
        // Extract base62 ID from Spotify URI
        let id = contentId.replacingOccurrences(of: "spotify:\\w+:", with: "", options: .regularExpression)

        let domain: String
        let service: String
        var data: [String: Any] = ["entity_id": Self.spotifyPlusEntityId]

        if contentId.hasPrefix("spotify:artist:") {
            domain = "spotifyplus"
            service = "get_artist_albums"
            data["artist_id"] = id
            data["include_groups"] = "album,single,compilation"
            data["limit_total"] = 10
        } else if contentId.hasPrefix("spotify:playlist:") {
            domain = "spotifyplus"
            service = "get_playlist_items"
            data["playlist_id"] = id
            data["limit_total"] = 50
        } else if contentId.hasPrefix("spotify:album:") {
            domain = "spotifyplus"
            service = "get_album_tracks"
            data["album_id"] = id
            data["limit_total"] = 50
        } else {
            return nil
        }

        do {
            let response = try await haClient.callServiceWithResponse(domain: domain, service: service, data: data)
            return parseBrowseResponse(response, contentType: contentType)
        } catch {
            errorMessage = "Browse failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Browse HA media root for a speaker (Favorites, Music Library, etc).
    func browseMediaRoot(entityId: String) async -> BrowseResult? {
        do {
            let response = try await haClient.callServiceWithResponse(
                domain: "media_player",
                service: "browse_media",
                data: ["entity_id": entityId]
            )
            return parseHABrowseResponse(response)
        } catch {
            return nil
        }
    }

    /// Browse into a HA media item by content ID/type.
    func browseMediaHA(entityId: String, contentId: String, contentType: String) async -> BrowseResult? {
        do {
            let response = try await haClient.callServiceWithResponse(
                domain: "media_player",
                service: "browse_media",
                data: [
                    "entity_id": entityId,
                    "media_content_id": contentId,
                    "media_content_type": contentType,
                ]
            )
            return parseHABrowseResponse(response)
        } catch {
            return nil
        }
    }

    // MARK: - Parsing

    private func parseHABrowseResponse(_ response: [String: Any]) -> BrowseResult? {
        let data = response["children"] != nil ? response : (response.values.first as? [String: Any] ?? response)
        let title = data["title"] as? String ?? "Browse"
        guard let children = data["children"] as? [[String: Any]] else {
            return BrowseResult(title: title, children: [])
        }

        let items = children.compactMap { child -> BrowseItem? in
            guard let childTitle = child["title"] as? String else { return nil }
            return BrowseItem(
                title: childTitle,
                mediaContentType: child["media_content_type"] as? String ?? "",
                mediaContentId: child["media_content_id"] as? String ?? "",
                canPlay: child["can_play"] as? Bool ?? false,
                canExpand: child["can_expand"] as? Bool ?? false,
                thumbnailPath: Self.thumbnailProxyPath(from: child["thumbnail"] as? String)
            )
        }
        return BrowseResult(title: title, children: items)
    }

    private func parseSpotifySearchResponse(_ response: [String: Any], category: String) -> [BrowseItem] {
        guard let result = response["result"] as? [String: Any] ?? response["response"] as? [String: Any],
            let items = result["items"] as? [[String: Any]]
        else {
            return []
        }

        return items.compactMap { item -> BrowseItem? in
            let actualItem = (item["track"] as? [String: Any]) ?? item
            guard let name = actualItem["name"] as? String,
                let uri = actualItem["uri"] as? String
            else { return nil }

            let type = (actualItem["type"] as? String) ?? category
            let thumbnailPath = extractThumbnailPath(from: actualItem)
            let canExpand = type == "artist" || type == "album" || type == "playlist"
            let canPlay = type == "track" || type == "album" || type == "playlist"

            return BrowseItem(
                title: name,
                mediaContentType: type,
                mediaContentId: uri,
                canPlay: canPlay,
                canExpand: canExpand,
                thumbnailPath: thumbnailPath
            )
        }
    }

    private func parseBrowseResponse(_ response: [String: Any], contentType: String) -> BrowseResult? {
        guard let result = response["response"] as? [String: Any] ?? response["result"] as? [String: Any],
            let items = result["items"] as? [[String: Any]]
        else {
            return nil
        }

        let title = (result["name"] as? String) ?? "Results"
        let children = items.compactMap { item -> BrowseItem? in
            let actualItem = (item["track"] as? [String: Any]) ?? item
            guard let name = actualItem["name"] as? String,
                let uri = actualItem["uri"] as? String
            else { return nil }

            let type = (actualItem["type"] as? String) ?? "track"
            let thumbnailPath = extractThumbnailPath(from: actualItem)
            let canExpand = type == "album" || type == "playlist"
            let canPlay = true

            return BrowseItem(
                title: name,
                mediaContentType: type,
                mediaContentId: uri,
                canPlay: canPlay,
                canExpand: canExpand,
                thumbnailPath: thumbnailPath
            )
        }

        return BrowseResult(title: title, children: children)
    }

    private func extractThumbnailPath(from item: [String: Any]) -> APIRequestPath? {
        if let path = Self.thumbnailProxyPath(from: item["image_url"] as? String) {
            return path
        }
        if let images = item["images"] as? [[String: Any]], let first = images.first {
            return Self.thumbnailProxyPath(from: first["url"] as? String)
        }
        if let album = item["album"] as? [String: Any],
            let images = album["images"] as? [[String: Any]], let first = images.first
        {
            return Self.thumbnailProxyPath(from: first["url"] as? String)
        }
        return nil
    }

    static func thumbnailProxyPath(from value: String?) -> APIRequestPath? {
        guard let value, isThumbnailProxyPath(value) else { return nil }
        let path = APIRequestPath(stringLiteral: value)
        guard (try? path.validatedValue()) != nil else { return nil }
        return path
    }

    nonisolated static func isThumbnailProxyPath(_ value: String) -> Bool {
        let prefix = "/home/media/thumbnails/"
        guard value.hasPrefix(prefix), value.utf8.count == prefix.utf8.count + 32 else {
            return false
        }
        return value.dropFirst(prefix.count).allSatisfy {
            $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0)))
        }
    }
}
