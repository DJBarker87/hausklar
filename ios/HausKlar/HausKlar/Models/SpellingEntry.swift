import Foundation
import SwiftData

/// Tracks spelling word lists, practice sessions, and test scores per child.
@Model
final class SpellingEntry {
    @Attribute(.unique) var id: String
    var childId: String
    /// JSON-encoded array of words.
    var wordList: String
    var testDate: Date?
    /// Score out of total words, nil if not yet tested.
    var score: Int?
    /// Number of times this word list has been practised.
    var practiceCount: Int
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        childId: String = "",
        wordList: String = "[]",
        testDate: Date? = nil,
        score: Int? = nil,
        practiceCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.childId = childId
        self.wordList = wordList
        self.testDate = testDate
        self.score = score
        self.practiceCount = practiceCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
