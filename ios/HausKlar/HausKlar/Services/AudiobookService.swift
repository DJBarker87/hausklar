import Foundation
import ImageIO
import UIKit

/// Authenticated Audiobookshelf adapter. All upstream metadata, covers,
/// progress and Home Assistant playback handoffs terminate at HausKlar's API;
/// the iOS process never receives an upstream token, URL, or LAN address.
@MainActor
final class AudiobookService {
    static let shared = AudiobookService()

    private let coverCache = NSCache<NSString, UIImage>()

    private init() {
        coverCache.countLimit = 80
        coverCache.totalCostLimit = 24 * 1024 * 1024
    }

    struct Library: Codable, Identifiable {
        let id: String
        let name: String
        let mediaType: String
    }

    struct LibrariesResponse: Codable {
        let libraries: [Library]
    }

    struct LibraryResponse: Codable {
        let results: [LibraryItem]
    }

    struct LibraryItem: Codable, Identifiable {
        let id: String
        let media: MediaInfo?

        struct MediaInfo: Codable {
            let metadata: Metadata?
            let duration: Double?
            let chapters: [Chapter]?

            struct Metadata: Codable {
                let title: String?
                let authorName: String?
                let narratorName: String?
                let description: String?
            }
        }

        var title: String { media?.metadata?.title ?? "Unknown" }
        var author: String { media?.metadata?.authorName ?? "Unknown" }
        var narrator: String? { media?.metadata?.narratorName }
        var duration: Double { media?.duration ?? 0 }
        var chapters: [Chapter] { media?.chapters ?? [] }
    }

    struct Chapter: Codable, Identifiable {
        let id: Int
        let title: String
        let start: Double
        let end: Double
    }

    struct ItemDetail: Codable {
        let id: String
        let media: LibraryItem.MediaInfo?
        let userMediaProgress: Progress?

        struct Progress: Codable {
            let currentTime: Double?
            let isFinished: Bool?
            let progress: Double?
        }

        var title: String { media?.metadata?.title ?? "Unknown" }
        var author: String { media?.metadata?.authorName ?? "Unknown" }
        var narrator: String? { media?.metadata?.narratorName }
        var duration: Double { media?.duration ?? 0 }
        var chapters: [Chapter] { media?.chapters ?? [] }
        var currentTime: Double { userMediaProgress?.currentTime ?? 0 }
        var isFinished: Bool { userMediaProgress?.isFinished ?? false }
        var progressFraction: Double { userMediaProgress?.progress ?? 0 }
    }

    struct PlayRequest: Encodable {
        let entityId: String
        let startTime: Double?
    }

    struct PlayResponse: Decodable {
        let available: Bool
        let handoffId: String?
        let reason: String?
    }

    private struct ProgressRequest: Encodable {
        let currentTime: Double
        let isFinished: Bool
    }

    private struct ProgressResponse: Decodable {
        let success: Bool
    }

    func fetchLibraries() async throws -> [Library] {
        let response: LibrariesResponse = try await APIClient.shared.get(
            "/home/audiobooks/libraries",
            cachePolicy: .networkThenStale
        )
        return response.libraries
    }

    func fetchLibraryItems(libraryId: String, limit: Int = 100) async throws -> [LibraryItem] {
        guard Self.validIdentifier(libraryId) else { throw AudiobookClientError.invalidIdentifier }
        let response: LibraryResponse = try await APIClient.shared.get(
            "/home/audiobooks/libraries/\(libraryId)/items",
            queryItems: [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))],
            cachePolicy: .networkThenStale
        )
        return response.results
    }

    func fetchItemDetail(itemId: String) async throws -> ItemDetail {
        guard Self.validIdentifier(itemId) else { throw AudiobookClientError.invalidIdentifier }
        return try await APIClient.shared.get(
            "/home/audiobooks/items/\(itemId)",
            cachePolicy: .networkThenStale
        )
    }

    func fetchCoverImage(itemId: String) async -> UIImage? {
        guard Self.validIdentifier(itemId),
              let ownerIdentity = APIClient.shared.cacheIdentity else { return nil }
        let key = "\(ownerIdentity)|\(itemId)" as NSString
        if let cached = coverCache.object(forKey: key) { return cached }
        do {
            let data = try await APIClient.shared.downloadData(
                "/home/audiobooks/items/\(itemId)/cover",
                policy: .image(maximumBytes: 8 * 1_024 * 1_024)
            )
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                Self.coverThumbnail(from: data)
            }).value,
                APIClient.shared.cacheIdentity == ownerIdentity else { return nil }
            let approximateCost = min(
                (image.cgImage?.width ?? 0) * (image.cgImage?.height ?? 0) * 4,
                24 * 1024 * 1024
            )
            coverCache.setObject(image, forKey: key, cost: approximateCost)
            return image
        } catch {
            return nil
        }
    }

    func clearCachedCovers() {
        coverCache.removeAllObjects()
    }

    nonisolated private static func coverThumbnail(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_600,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    func play(itemId: String, entityId: String, startTime: Double? = nil) async throws -> PlayResponse {
        guard Self.validIdentifier(itemId),
              Self.validMediaPlayerEntityID(entityId) else {
            throw AudiobookClientError.invalidIdentifier
        }
        let response: PlayResponse = try await APIClient.shared.post(
            "/home/audiobooks/items/\(itemId)/play",
            body: PlayRequest(entityId: entityId, startTime: startTime)
        )
        return response
    }

    func updateProgress(
        itemId: String,
        currentTime: Double,
        isFinished: Bool = false
    ) async throws {
        guard Self.validIdentifier(itemId),
              currentTime.isFinite,
              (0...10_000_000).contains(currentTime) else {
            throw AudiobookClientError.invalidIdentifier
        }
        let _: ProgressResponse = try await APIClient.shared.patch(
            "/home/audiobooks/items/\(itemId)/progress",
            body: ProgressRequest(currentTime: currentTime, isFinished: isFinished)
        )
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }

    static func validMediaPlayerEntityID(_ value: String) -> Bool {
        guard value.hasPrefix("media_player.") else { return false }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy {
                $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
            }
        }
    }
}

enum AudiobookClientError: LocalizedError {
    case invalidIdentifier

    var errorDescription: String? {
        "That audiobook request is invalid."
    }
}
