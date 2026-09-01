import Foundation

// MARK: - Child Photo DTOs
// Contract for /child-photos/ — an explicit, self-hosted gallery of the children.
// Deliberately separate from the Immich-backed photo *search*: this is a place to
// hand-pick and keep photos, with no dependency on any external photo app.

struct ChildPhotoDTO: Codable, Identifiable, Equatable {
    let id: String
    let childId: String
    // Nullable: the backend LEFT JOINs the child, so a soft-deleted child returns null.
    let childName: String?
    let caption: String?
    /// Capture date ("YYYY-MM-DD") — the real camera-roll date, read on-device from EXIF.
    let takenOn: String
    let location: String?
    let story: String?
    let favourite: Bool?
    let includeInYearbook: Bool?
    let yearbookPosition: Int?
    let originalAvailable: Bool?
    let createdAt: String
    let updatedAt: String?
    let imageUrl: String
    let originalImageUrl: String?

    /// Child name for display, falling back to a neutral label when the child is gone.
    var childDisplayName: String {
        childName ?? "Unknown"
    }

    /// The capture date as a local `Date`, for editing in a DatePicker.
    var takenOnDate: Date? {
        ISODateParser.parseDateOnly(takenOn)
    }

    /// Human-readable capture date, e.g. "12 July 2026".
    var takenOnLabel: String {
        guard let date = takenOnDate else { return takenOn }
        return ISODateParser.enGBLongDate(from: date)
    }
}

/// Response envelope for POST /child-photos/ — a batch returns `{"photos":[...]}`.
struct ChildPhotoUploadResponse: Decodable {
    let photos: [ChildPhotoDTO]
}

/// JSON body for PATCH /child-photos/{id}. Nil fields are omitted (partial update).
struct ChildPhotoUpdateRequest: Encodable {
    let caption: String?
    let takenOn: String
    let childId: String
    let location: String?
    let story: String?
    let favourite: Bool
    let includeInYearbook: Bool

    enum CodingKeys: String, CodingKey {
        case caption, takenOn, childId, location, story, favourite, includeInYearbook
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(caption, forKey: .caption)
        try container.encode(takenOn, forKey: .takenOn)
        try container.encode(childId, forKey: .childId)
        try container.encode(location, forKey: .location)
        try container.encode(story, forKey: .story)
        try container.encode(favourite, forKey: .favourite)
        try container.encode(includeInYearbook, forKey: .includeInYearbook)
    }
}

extension ChildPhotoDTO {
    /// Formats a `Date` as the backend's capture-date format, "YYYY-MM-DD" (local calendar).
    static func takenOnValue(from date: Date) -> String {
        ISODateParser.stringDateOnly(from: date)
    }
}
