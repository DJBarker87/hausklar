import Foundation

// MARK: - Photo Search DTOs
// Contract for /photos/search — semantic recall over the family photo archive.

struct PhotoSearchResultDTO: Codable, Identifiable {
    let assetId: String
    let takenAt: String?
    let thumbnailUrl: String

    var id: String { assetId }

    /// "12 July 2026" or nil when the capture date is unknown.
    var takenAtDisplay: String? {
        guard let takenAt, let date = ISODateParser.parse(takenAt) else { return nil }
        return ISODateParser.dateOnly(from: date)
    }
}

struct PhotoSearchResponseDTO: Codable {
    let query: String
    let results: [PhotoSearchResultDTO]
}
