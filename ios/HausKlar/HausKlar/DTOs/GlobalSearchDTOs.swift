import Foundation

enum GlobalSearchResultKindDTO: String, Codable {
    case event
    case task
    case document
    case person
    case photo
    case artwork
    case homework
    case health
    case renewal
    case birthday
}

struct GlobalSearchResultDTO: Codable, Identifiable, Equatable {
    let id: String
    let kind: GlobalSearchResultKindDTO
    let title: String
    let subtitle: String?
    let date: String?
    let imageUrl: String?
    let childId: String?
    let path: String
}

struct GlobalSearchResponseDTO: Codable, Equatable {
    let query: String
    let results: [GlobalSearchResultDTO]
    let hasMore: Bool
}
