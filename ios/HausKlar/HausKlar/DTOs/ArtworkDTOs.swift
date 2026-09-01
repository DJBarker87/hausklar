import Foundation

// MARK: - Artwork DTOs
// Contract for /artworks/ — the kids' artwork archive.

struct ArtworkDTO: Codable, Identifiable {
    let id: String
    let childId: String
    // Nullable: the backend LEFT JOINs the child, so a soft-deleted child returns null.
    let childName: String?
    let title: String?
    let approxDate: String
    let datePrecision: String
    let ageLabel: String?
    let notes: String?
    let medium: String?
    let story: String?
    let childQuote: String?
    let schoolYear: String?
    let favourite: Bool?
    let includeInYearbook: Bool?
    let yearbookPosition: Int?
    let originalAvailable: Bool?
    let rotationDegrees: Int?
    let enhanced: Bool?
    let createdAt: String
    let updatedAt: String?
    let imageUrl: String
    let originalImageUrl: String?

    /// Child name for display, falling back to a neutral label when the child is gone.
    var childDisplayName: String {
        childName ?? "Unknown"
    }

    /// Human-readable form of the rough date, e.g. "2026", "July 2026" or "12 July 2026".
    var dateLabel: String {
        ApproxDate(string: approxDate)?.displayLabel ?? approxDate
    }
}

/// JSON body for PATCH /artworks/{id}. Nil fields are omitted (partial update).
struct ArtworkUpdateRequest: Encodable {
    let title: String?
    let approxDate: String
    let childId: String
    let notes: String?
    let medium: String?
    let story: String?
    let childQuote: String?
    let schoolYear: String?
    let favourite: Bool
    let includeInYearbook: Bool
    let yearbookPosition: Int?

    enum CodingKeys: String, CodingKey {
        case title, approxDate, childId, notes, medium, story, childQuote, schoolYear
        case favourite, includeInYearbook, yearbookPosition
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(approxDate, forKey: .approxDate)
        try container.encode(childId, forKey: .childId)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(medium, forKey: .medium)
        try container.encodeIfPresent(story, forKey: .story)
        try container.encodeIfPresent(childQuote, forKey: .childQuote)
        try container.encodeIfPresent(schoolYear, forKey: .schoolYear)
        try container.encode(favourite, forKey: .favourite)
        try container.encode(includeInYearbook, forKey: .includeInYearbook)
        try container.encodeIfPresent(yearbookPosition, forKey: .yearbookPosition)
    }
}

struct ArtworkAppearanceRequest: Encodable {
    let rotationDegrees: Int
    let enhanced: Bool
}

/// A deliberately rough date: always a year, optionally a month, optionally a day.
/// Serialised as "2026", "2026-07" or "2026-07-12" — never forced to full precision.
struct ApproxDate: Equatable {
    let year: Int
    let month: Int?
    let day: Int?

    init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        // A day is only meaningful when a month is set.
        self.day = month == nil ? nil : day
    }

    /// Parses "2026", "2026-07" or "2026-07-12". Returns nil for anything else.
    init?(string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count),
              parts[0].count == 4, let year = Int(parts[0]), (1900...2999).contains(year) else {
            return nil
        }
        var month: Int?
        var day: Int?
        if parts.count > 1 {
            guard parts[1].count == 2, let value = Int(parts[1]), (1...12).contains(value) else { return nil }
            month = value
        }
        if parts.count > 2 {
            guard parts[2].count == 2, let value = Int(parts[2]), (1...31).contains(value) else { return nil }
            day = value
        }
        self.year = year
        self.month = month
        self.day = day
    }

    var precision: String {
        if day != nil { return "day" }
        if month != nil { return "month" }
        return "year"
    }

    /// API value: "2026", "2026-07" or "2026-07-12".
    var apiValue: String {
        if let month, let day { return String(format: "%04d-%02d-%02d", year, month, day) }
        if let month { return String(format: "%04d-%02d", year, month) }
        return String(format: "%04d", year)
    }

    private static let monthSymbols = DateFormatter().standaloneMonthSymbols ?? []

    /// Display label: "2026", "July 2026" or "12 July 2026".
    var displayLabel: String {
        guard let month, (1...12).contains(month), Self.monthSymbols.count == 12 else { return String(year) }
        let monthName = Self.monthSymbols[month - 1]
        if let day { return "\(day) \(monthName) \(year)" }
        return "\(monthName) \(year)"
    }
}
