import Foundation
import SwiftUI

struct ReadingLogDTO: Codable, Identifiable, Equatable {
    let id: String
    let childId: String
    let bookTitle: String
    let minutes: Int
    let date: String
    let notes: String?
}

struct SpellingAttemptDTO: Codable, Equatable, Hashable {
    let word: String
    let correct: Bool
}

struct SpellingPracticeDTO: Codable, Identifiable, Equatable {
    let id: String
    let practisedAt: String
    let attempts: [SpellingAttemptDTO]
    let correctCount: Int
    let totalCount: Int
}

struct SpellingMasteryDTO: Codable, Identifiable, Equatable {
    var id: String { word }
    let word: String
    let attempts: Int
    let correctAttempts: Int
    let mastered: Bool
    let needsPractice: Bool
}

struct SpellingsDTO: Codable, Identifiable, Equatable {
    let id: String
    let childId: String
    let wordList: [String]
    let testDate: String
    let score: Int?
    let practiceCount: Int
    let completedAt: String?
    let notes: String?
    let linkUrl: String?
    let sourceDocumentId: String?
    let sourceDocument: SourceDocumentDTO?
    let status: String?
    let practiceSessions: [SpellingPracticeDTO]?
    let mastery: [SpellingMasteryDTO]?

    var sessions: [SpellingPracticeDTO] { practiceSessions ?? [] }
    var wordMastery: [SpellingMasteryDTO] { mastery ?? [] }
    var isCompleted: Bool { completedAt != nil || status == "completed" }
}

private struct ReadingCreateRequest: Encodable {
    let childId: String
    let bookTitle: String
    let minutes: Int
    let date: String
    let notes: String?
}

private struct ReadingUpdateRequest: Encodable {
    let bookTitle: String
    let minutes: Int
    let date: String
    let notes: String?
}

private struct SpellingsCreateRequest: Encodable {
    let childId: String
    let wordList: [String]
    let testDate: String
    let notes: String?
    let linkUrl: String?
    let sourceDocumentId: String?
}

private struct SpellingsUpdateRequest: Encodable {
    let wordList: [String]
    let testDate: String
    let notes: String?
    let linkUrl: String?
    let sourceDocumentId: String?

    enum CodingKeys: String, CodingKey {
        case wordList, testDate, notes, linkUrl, sourceDocumentId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wordList, forKey: .wordList)
        try container.encode(testDate, forKey: .testDate)
        try container.encode(notes, forKey: .notes)
        try container.encode(linkUrl, forKey: .linkUrl)
        try container.encode(sourceDocumentId, forKey: .sourceDocumentId)
    }
}

private struct SpellingPracticeRequest: Encodable {
    let attempts: [SpellingAttemptDTO]
    let practisedAt: String?
}

private struct SpellingCompleteRequest: Encodable {
    let score: Int?
}

private struct EmptyHomeworkRequest: Encodable {}

enum HomeworkUndoKind {
    case reading
    case spellings
}

struct HomeworkUndoNotice: Identifiable {
    let id = UUID()
    let recordId: String
    let kind: HomeworkUndoKind
    let message: String
}

@MainActor
final class HomeworkViewModel: ObservableObject {
    @Published var children: [ChildDTO] = []
    @Published var selectedChildId: String?
    @Published var readingLogs: [ReadingLogDTO] = []
    @Published var spellings: [SpellingsDTO] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var actionError: String?
    @Published var noticeMessage: String?
    @Published var undoNotice: HomeworkUndoNotice?

    @Published var showingReadingEditor = false
    @Published var editingReading: ReadingLogDTO?
    @Published var readingBookTitle = ""
    @Published var readingMinutes = 15
    @Published var readingDate = Date()
    @Published var readingNotes = ""

    @Published var showingSpellingsEditor = false
    @Published var editingSpellings: SpellingsDTO?
    @Published var spellingsWords = ""
    @Published var spellingsTestDate = Date()
    @Published var spellingsNotes = ""
    @Published var spellingsLink = ""
    @Published var spellingsDocument: SourceDocumentDTO?

    @Published var focusedSpellings: SpellingsDTO?
    @Published var practiceSpellings: SpellingsDTO?
    @Published var correctingPracticeId: String?
    @Published var practiceIndex = 0
    @Published var practiceWordRevealed = false
    @Published var practiceResults: [String: Bool] = [:]

    @Published var completingSpellings: SpellingsDTO?
    @Published var completionScore = ""

    private let apiClient: APIClient
    private let defaults: UserDefaults
    private let initialChildId: String?
    private let initialSpellingsId: String?
    private let initialReadingId: String?
    private var hasAppliedInitialFocus = false

    private enum CacheKeys {
        static let children = "homework.children.cache"
        static let readingLogs = "homework.reading.cache"
        static let spellings = "homework.spellings.cache"
        static let selectedChild = "homework.selectedChild"
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    init(
        initialChildId: String? = nil,
        initialSpellingsId: String? = nil,
        initialReadingId: String? = nil,
        apiClient: APIClient = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.initialChildId = initialChildId
        self.initialSpellingsId = initialSpellingsId
        self.initialReadingId = initialReadingId
        self.apiClient = apiClient
        self.defaults = defaults
        selectedChildId = initialChildId ?? defaults.string(forKey: CacheKeys.selectedChild)
        loadCachedData()
    }

    var selectedChild: ChildDTO? {
        children.first { $0.id == selectedChildId }
    }

    var latestReading: ReadingLogDTO? {
        readingLogs.max { left, right in
            if left.date == right.date { return left.id < right.id }
            return left.date < right.date
        }
    }

    var weeklyReadingMinutes: Int {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return readingLogs.reduce(into: 0) { total, log in
            if let date = Self.dateOnlyFormatter.date(from: log.date), date >= start {
                total += log.minutes
            }
        }
    }

    var upcomingSpellings: [SpellingsDTO] {
        spellings.filter { !$0.isCompleted }.sorted { $0.testDate < $1.testDate }
    }

    var completedSpellings: [SpellingsDTO] {
        spellings.filter(\.isCompleted).sorted { $0.testDate > $1.testDate }
    }

    var recentReading: [ReadingLogDTO] {
        Array(readingLogs.sorted { $0.date > $1.date }.prefix(12))
    }

    var practiceWord: String? {
        guard let entry = practiceSpellings,
              entry.wordList.indices.contains(practiceIndex) else { return nil }
        return entry.wordList[practiceIndex]
    }

    var parsedSpellingWords: [String] {
        var seen = Set<String>()
        return spellingsWords
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { word in
                guard !word.isEmpty else { return false }
                return seen.insert(word.lowercased()).inserted
            }
    }

    func load() async {
        isLoading = children.isEmpty
        errorMessage = nil
        defer { isLoading = false }
        do {
            let fetched: [ChildDTO] = try await apiClient.get("/children/")
            children = fetched
            persist(fetched, key: CacheKeys.children)
            let requested = initialChildId ?? selectedChildId
            if let requested, fetched.contains(where: { $0.id == requested }) {
                selectedChildId = requested
            } else {
                selectedChildId = fetched.first?.id
            }
            rememberSelectedChild()
            await loadSelectedChild()
        } catch {
            if children.isEmpty {
                errorMessage = "Homework could not be loaded. Pull to try again."
            } else {
                await loadSelectedChild()
            }
        }
    }

    func selectChild(_ childId: String) async {
        guard childId != selectedChildId else { return }
        selectedChildId = childId
        rememberSelectedChild()
        focusedSpellings = nil
        await loadSelectedChild()
    }

    func loadSelectedChild() async {
        guard let childId = selectedChildId else {
            readingLogs = []
            spellings = []
            return
        }
        actionError = nil
        let query = [URLQueryItem(name: "child_id", value: childId)]
        do {
            async let readingRequest: [ReadingLogDTO] = apiClient.get(
                "/homework/reading", queryItems: query
            )
            async let spellingRequest: [SpellingsDTO] = apiClient.get(
                "/homework/spellings", queryItems: query
            )
            let (loadedReading, loadedSpellings) = try await (readingRequest, spellingRequest)
            readingLogs = loadedReading
            spellings = loadedSpellings
            persist(loadedReading, key: CacheKeys.readingLogs)
            persist(loadedSpellings, key: CacheKeys.spellings)
            applyInitialFocusIfNeeded()
        } catch {
            if readingLogs.isEmpty && spellings.isEmpty {
                errorMessage = "Homework could not be loaded. Pull to try again."
            }
        }
    }

    func quickLogUsualReading() async {
        guard let childId = selectedChildId, let latestReading else {
            prepareReadingEditor()
            return
        }
        actionError = nil
        do {
            let body = ReadingCreateRequest(
                childId: childId,
                bookTitle: latestReading.bookTitle,
                minutes: latestReading.minutes,
                date: Self.dateOnlyFormatter.string(from: Date()),
                notes: nil
            )
            let saved: ReadingLogDTO = try await apiClient.post("/homework/reading", body: body)
            noticeMessage = "Logged (saved.minutes) minutes of (saved.bookTitle)."
            undoNotice = HomeworkUndoNotice(
                recordId: saved.id,
                kind: .reading,
                message: "Reading logged"
            )
            await loadSelectedChild()
        } catch {
            actionError = "That reading session could not be saved."
        }
    }

    func prepareReadingEditor(_ log: ReadingLogDTO? = nil) {
        editingReading = log
        let suggested = log ?? latestReading
        readingBookTitle = suggested?.bookTitle ?? ""
        readingMinutes = suggested?.minutes ?? 15
        readingDate = log.flatMap { Self.dateOnlyFormatter.date(from: $0.date) } ?? Date()
        readingNotes = log?.notes ?? ""
        actionError = nil
        showingReadingEditor = true
    }

    func saveReading() async {
        guard let childId = selectedChildId else { return }
        let title = readingBookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            actionError = "Enter the book title."
            return
        }
        actionError = nil
        do {
            let date = Self.dateOnlyFormatter.string(from: readingDate)
            let notes = nilIfEmpty(readingNotes)
            if let editingReading {
                let body = ReadingUpdateRequest(
                    bookTitle: title, minutes: readingMinutes, date: date, notes: notes
                )
                let _: ReadingLogDTO = try await apiClient.put(
                    "/homework/reading/\(editingReading.id)", body: body
                )
                noticeMessage = "Reading session corrected."
            } else {
                let body = ReadingCreateRequest(
                    childId: childId,
                    bookTitle: title,
                    minutes: readingMinutes,
                    date: date,
                    notes: notes
                )
                let _: ReadingLogDTO = try await apiClient.post("/homework/reading", body: body)
                noticeMessage = "Reading logged."
            }
            showingReadingEditor = false
            await loadSelectedChild()
        } catch {
            actionError = "That reading session could not be saved."
        }
    }

    func deleteReading(_ log: ReadingLogDTO) async {
        do {
            try await apiClient.delete("/homework/reading/\(log.id)")
            undoNotice = HomeworkUndoNotice(
                recordId: log.id,
                kind: .reading,
                message: "Reading session removed"
            )
            await loadSelectedChild()
        } catch {
            actionError = "That reading session could not be removed."
        }
    }

    func prepareSpellingsEditor(_ entry: SpellingsDTO? = nil) {
        editingSpellings = entry
        spellingsWords = entry?.wordList.joined(separator: "\n") ?? ""
        spellingsTestDate = entry.flatMap { Self.dateOnlyFormatter.date(from: $0.testDate) }
            ?? Calendar.current.date(byAdding: .day, value: 7, to: Date())
            ?? Date()
        spellingsNotes = entry?.notes ?? ""
        spellingsLink = entry?.linkUrl ?? ""
        spellingsDocument = entry?.sourceDocument
        actionError = nil
        showingSpellingsEditor = true
    }

    func saveSpellings() async {
        guard let childId = selectedChildId else { return }
        let words = parsedSpellingWords
        guard !words.isEmpty else {
            actionError = "Paste or enter at least one spelling word."
            return
        }
        guard words.count <= 100 else {
            actionError = "Keep each spelling list to 100 words or fewer."
            return
        }
        let link = nilIfEmpty(spellingsLink)
        if let link, SafeExternalURL.web(link) == nil {
            actionError = "Enter a full secure web link beginning with https."
            return
        }
        actionError = nil
        do {
            let testDate = Self.dateOnlyFormatter.string(from: spellingsTestDate)
            if let editingSpellings {
                let body = SpellingsUpdateRequest(
                    wordList: words,
                    testDate: testDate,
                    notes: nilIfEmpty(spellingsNotes),
                    linkUrl: link,
                    sourceDocumentId: spellingsDocument?.id
                )
                let updated: SpellingsDTO = try await apiClient.put(
                    "/homework/spellings/\(editingSpellings.id)", body: body
                )
                focusedSpellings = updated
                noticeMessage = "Spelling list corrected."
            } else {
                let body = SpellingsCreateRequest(
                    childId: childId,
                    wordList: words,
                    testDate: testDate,
                    notes: nilIfEmpty(spellingsNotes),
                    linkUrl: link,
                    sourceDocumentId: spellingsDocument?.id
                )
                let created: SpellingsDTO = try await apiClient.post("/homework/spellings", body: body)
                focusedSpellings = created
                noticeMessage = "Spelling list ready to practise."
            }
            showingSpellingsEditor = false
            await loadSelectedChild()
        } catch {
            actionError = "That spelling list could not be saved."
        }
    }

    func beginPractice(_ entry: SpellingsDTO, correcting session: SpellingPracticeDTO? = nil) {
        practiceSpellings = entry
        correctingPracticeId = session?.id
        practiceResults = Dictionary(
            uniqueKeysWithValues: (session?.attempts ?? []).map { ($0.word, $0.correct) }
        )
        practiceIndex = 0
        practiceWordRevealed = false
        actionError = nil
    }

    func previousPracticeWord() {
        guard practiceIndex > 0 else { return }
        practiceIndex -= 1
        practiceWordRevealed = false
    }

    func recordPracticeAnswer(_ correct: Bool) async {
        guard let entry = practiceSpellings, let word = practiceWord else { return }
        practiceResults[word] = correct
        if practiceIndex < entry.wordList.count - 1 {
            practiceIndex += 1
            practiceWordRevealed = false
            return
        }
        await savePractice()
    }

    func savePractice() async {
        guard let entry = practiceSpellings,
              entry.wordList.allSatisfy({ practiceResults[$0] != nil }) else {
            actionError = "Finish each word before saving this practice."
            return
        }
        let attempts = entry.wordList.map {
            SpellingAttemptDTO(word: $0, correct: practiceResults[$0] == true)
        }
        let body = SpellingPracticeRequest(attempts: attempts, practisedAt: nil)
        do {
            let updated: SpellingsDTO
            if let correctingPracticeId {
                updated = try await apiClient.put(
                    "/homework/spellings/\(entry.id)/practice/\(correctingPracticeId)",
                    body: body
                )
                noticeMessage = "Practice session corrected."
            } else {
                updated = try await apiClient.post(
                    "/homework/spellings/\(entry.id)/practice", body: body
                )
                noticeMessage = "Practice saved — \(attempts.filter(\.correct).count) of \(attempts.count) correct."
            }
            practiceSpellings = nil
            focusedSpellings = updated
            await loadSelectedChild()
        } catch {
            actionError = "That practice could not be saved."
        }
    }

    func prepareCompletion(_ entry: SpellingsDTO) {
        completingSpellings = entry
        completionScore = entry.score.map(String.init) ?? ""
        actionError = nil
    }

    func completeSpellings() async {
        guard let entry = completingSpellings else { return }
        let score = completionScore.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : Int(completionScore)
        if let score, !(0...entry.wordList.count).contains(score) {
            actionError = "Enter a score from 0 to \(entry.wordList.count)."
            return
        }
        do {
            let body = SpellingCompleteRequest(score: score)
            let updated: SpellingsDTO = try await apiClient.post(
                "/homework/spellings/\(entry.id)/complete", body: body
            )
            completingSpellings = nil
            focusedSpellings = updated
            noticeMessage = "Spelling test marked done."
            await loadSelectedChild()
        } catch {
            actionError = "That result could not be saved."
        }
    }

    func reopenSpellings(_ entry: SpellingsDTO) async {
        do {
            let updated: SpellingsDTO = try await apiClient.post(
                "/homework/spellings/\(entry.id)/reopen", body: EmptyHomeworkRequest()
            )
            focusedSpellings = updated
            noticeMessage = "Spelling list reopened."
            await loadSelectedChild()
        } catch {
            actionError = "That spelling list could not be reopened."
        }
    }

    func deleteSpellings(_ entry: SpellingsDTO) async {
        do {
            try await apiClient.delete("/homework/spellings/\(entry.id)")
            focusedSpellings = nil
            undoNotice = HomeworkUndoNotice(
                recordId: entry.id,
                kind: .spellings,
                message: "Spelling list removed"
            )
            await loadSelectedChild()
        } catch {
            actionError = "That spelling list could not be removed."
        }
    }

    func undoLastRemoval() async {
        guard let undoNotice else { return }
        do {
            switch undoNotice.kind {
            case .reading:
                let _: ReadingLogDTO = try await apiClient.post(
                    "/homework/reading/\(undoNotice.recordId)/restore",
                    body: EmptyHomeworkRequest()
                )
            case .spellings:
                let _: SpellingsDTO = try await apiClient.post(
                    "/homework/spellings/\(undoNotice.recordId)/restore",
                    body: EmptyHomeworkRequest()
                )
            }
            self.undoNotice = nil
            noticeMessage = "Restored."
            await loadSelectedChild()
        } catch {
            actionError = "That item could not be restored."
        }
    }

    func dueLabel(_ entry: SpellingsDTO) -> String {
        guard let due = Self.dateOnlyFormatter.date(from: entry.testDate) else {
            return entry.testDate
        }
        if entry.isCompleted {
            return "Tested \(due.formatted(date: .abbreviated, time: .omitted))"
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: due)
        ).day ?? 0
        switch days {
        case ..<0: return days == -1 ? "Due yesterday" : "Overdue by \(-days) days"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Test \(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        }
    }

    func formatDate(_ value: String) -> String {
        Self.dateOnlyFormatter.date(from: value)?.formatted(date: .abbreviated, time: .omitted)
            ?? value
    }

    func formatDateTime(_ value: String) -> String {
        ISODateParser.parse(value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }

    private func applyInitialFocusIfNeeded() {
        guard !hasAppliedInitialFocus else { return }
        hasAppliedInitialFocus = true
        if let initialSpellingsId {
            focusedSpellings = spellings.first { $0.id == initialSpellingsId }
        } else if let initialReadingId,
                  let reading = readingLogs.first(where: { $0.id == initialReadingId }) {
            prepareReadingEditor(reading)
        }
    }

    private func rememberSelectedChild() {
        if let selectedChildId {
            defaults.set(selectedChildId, forKey: CacheKeys.selectedChild)
        }
    }

    private func loadCachedData() {
        children = loadCached(key: CacheKeys.children) ?? []
        readingLogs = loadCached(key: CacheKeys.readingLogs) ?? []
        spellings = loadCached(key: CacheKeys.spellings) ?? []
        if let selectedChildId,
           !children.isEmpty,
           !children.contains(where: { $0.id == selectedChildId }) {
            self.selectedChildId = children.first?.id
        }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        // This UserDefaults value is only a stale offline presentation cache;
        // the server and durable sync store remain authoritative.
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadCached<T: Decodable>(key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        // Schema drift or corruption deliberately invalidates this optional
        // cache and lets the normal network loading/error state take over.
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
