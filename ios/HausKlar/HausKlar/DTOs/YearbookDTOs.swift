import Foundation

// MARK: - Yearbook DTOs
// Contract for /yearbook/{child_id}/{year} — the per-child, per-year keepsake.
// Decoded with `.convertFromSnakeCase`, so snake_case keys map to these camelCase
// properties automatically. Almost everything is optional or may be empty/zero: a
// sparse year must still decode cleanly (narrative, growth, titles, notes, location
// and every measurement can be null).

struct YearbookDTO: Codable, Equatable {
    let child: Child
    let year: Int
    let narrative: String?
    let sections: Sections

    struct Child: Codable, Equatable {
        let id: String
        let name: String
        let age: Int
    }

    struct Sections: Codable, Equatable {
        let artwork: Artwork
        let growth: Growth?
        let starCharts: StarCharts
        let learning: Learning
        let illnesses: Illnesses
        let adventures: Adventures
        let favouriteMeals: [String]
        let photos: Photos
    }

    struct Artwork: Codable, Equatable {
        let count: Int
        let items: [Item]

        struct Item: Codable, Equatable, Identifiable {
            let id: String
            let title: String?
            let approxDate: String
            let imageUrl: String

            /// Human-readable rough date, e.g. "2025", "March 2025".
            var dateLabel: String {
                ApproxDate(string: approxDate)?.displayLabel ?? approxDate
            }
        }
    }

    struct Growth: Codable, Equatable {
        let start: Point
        let end: Point
        let grewCm: Double?
        let gainedKg: Double?
        let measurements: Int

        struct Point: Codable, Equatable {
            let date: String
            let heightCm: Double?
            let weightKg: Double?
        }
    }

    struct StarCharts: Codable, Equatable {
        let completed: Int
        let earnedPence: Int
        let titles: [String]

        /// Reward total formatted as pounds, e.g. "£15.00".
        var earnedDisplay: String {
            String(format: "£%.2f", Double(earnedPence) / 100)
        }
    }

    struct Learning: Codable, Equatable {
        let readingSessions: Int
        let minutesRead: Int
        let books: [String]
        let bookCount: Int
        let spellingTests: Int
    }

    struct Illnesses: Codable, Equatable {
        let count: Int
        let items: [Item]

        struct Item: Codable, Equatable {
            let startedAt: String
            let notes: String?
        }
    }

    struct Adventures: Codable, Equatable {
        let count: Int
        let items: [Item]

        struct Item: Codable, Equatable, Identifiable {
            let title: String
            let startTime: String
            let location: String?

            var id: String { startTime + title }
        }
    }

    struct Photos: Codable, Equatable {
        let count: Int
        let highlights: [Highlight]

        struct Highlight: Codable, Equatable, Identifiable {
            let assetId: String
            let thumbnailUrl: String

            var id: String { assetId }
        }
    }

    /// A quiet year has nothing worth its own section — but should still read as a keepsake.
    var isQuiet: Bool {
        narrative == nil
            && sections.artwork.count == 0
            && sections.growth == nil
            && sections.starCharts.completed == 0
            && sections.learning.readingSessions == 0
            && sections.learning.bookCount == 0
            && sections.learning.spellingTests == 0
            && sections.adventures.count == 0
            && sections.favouriteMeals.isEmpty
            && sections.illnesses.count == 0
            && sections.photos.count == 0
    }
}

/// Contract for GET /yearbook/{child_id}/years — newest first, current year always present.
struct YearbookYearsDTO: Codable, Equatable {
    let years: [Int]
}

/// Every photo and artwork candidate for the calm choose-and-arrange builder,
/// including items that a parent has deliberately left out.
struct YearbookOptionsDTO: Codable, Equatable {
    let child: Child
    let year: Int
    let artwork: [ArtworkCandidate]
    let photos: [PhotoCandidate]

    struct Child: Codable, Equatable {
        let id: String
        let name: String
    }

    struct ArtworkCandidate: Codable, Equatable, Identifiable {
        let id: String
        let title: String?
        let approxDate: String
        let includeInYearbook: Bool
        let yearbookPosition: Int?
        let imageUrl: String
    }

    struct PhotoCandidate: Codable, Equatable, Identifiable {
        let id: String
        let caption: String?
        let takenOn: String
        let location: String?
        let includeInYearbook: Bool
        let yearbookPosition: Int?
        let imageUrl: String
    }
}

struct YearbookArrangementRequest: Encodable {
    let artworkIds: [String]
    let photoIds: [String]
}
