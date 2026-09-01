import Foundation

// MARK: - Photo Memory DTOs
// Contract for GET /photos/memories — "on this day" photos from previous years.

struct PhotoMemoryDTO: Codable, Identifiable {
    let assetId: String
    // Nullable: an Immich asset can lack a capture timestamp.
    let takenAt: String?
    let yearsAgo: Int
    let thumbnailUrl: String

    var id: String { assetId }

    var caption: String {
        yearsAgo == 1 ? "One year ago" : "\(yearsAgo) years ago"
    }
}

struct PhotoMemoriesResponseDTO: Codable {
    let generatedAt: String
    let memories: [PhotoMemoryDTO]
}
