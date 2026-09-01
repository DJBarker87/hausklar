import Foundation

actor FitnessCoachService {
    static let shared = FitnessCoachService()

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) { self.apiClient = apiClient }

    func status() async throws -> FitnessCoachStatus {
        try await apiClient.get("/fitness/coach/status",bypassCache: true)
    }

    func recommendations() async throws -> [FitnessCoachRecommendation] {
        try await apiClient.get("/fitness/coach/recommendations",bypassCache: true)
    }

    func preferences() async throws -> FitnessCoachPreferences {
        try await apiClient.get("/fitness/coach/preferences",bypassCache: true)
    }

    func updatePreferences(_ preferences: FitnessCoachPreferences) async throws -> FitnessCoachPreferences {
        try await apiClient.patch(
            "/fitness/coach/preferences",body: FitnessCoachPreferencesUpdate(preferences)
        )
    }

    func contextPreferences() async throws -> FitnessCoachContextPreferences {
        try await apiClient.get(
            "/fitness/coach/context-preferences",bypassCache: true
        )
    }

    func updateContextPreferences(
        _ preferences: FitnessCoachContextPreferences
    ) async throws -> FitnessCoachContextPreferences {
        try await apiClient.patch(
            "/fitness/coach/context-preferences",
            body: FitnessCoachContextPreferencesUpdate(
                familyCalendar: preferences.familyCalendar,
                householdMeals: preferences.householdMeals,
                weather: preferences.weather
            )
        )
    }

    func reminders() async throws -> [FitnessCoachReminder] {
        try await apiClient.get("/fitness/coach/reminders",bypassCache: true)
    }

    func deleteReminder(_ id: String) async throws {
        try await apiClient.delete("/fitness/coach/reminders/\(id)")
    }

    func send(_ request: FitnessCoachMessageRequest) async throws -> FitnessCoachMessageResponse {
        try await apiClient.post(
            "/fitness/coach/message",body: request,timeoutInterval: 135
        )
    }

    func memorySettings() async throws -> FitnessCoachMemorySettings {
        try await apiClient.get("/fitness/coach/memory/settings",bypassCache: true)
    }

    func updateMemorySettings(enabled: Bool) async throws -> FitnessCoachMemorySettings {
        try await apiClient.put(
            "/fitness/coach/memory/settings",body: FitnessCoachMemorySettingsUpdate(enabled: enabled)
        )
    }

    func conversations() async throws -> [FitnessCoachConversation] {
        try await apiClient.get("/fitness/coach/conversations",bypassCache: true)
    }

    func createConversation(title: String? = nil) async throws -> FitnessCoachConversation {
        try await apiClient.post(
            "/fitness/coach/conversations",
            body: FitnessCoachConversationCreate(id: UUID().uuidString,title: title)
        )
    }

    func conversation(_ id: String) async throws -> FitnessCoachConversationDetail {
        try await apiClient.get(
            "/fitness/coach/conversations/\(id)",bypassCache: true
        )
    }

    func deleteConversation(_ id: String) async throws {
        try await apiClient.delete("/fitness/coach/conversations/\(id)")
    }

    func memories() async throws -> [FitnessCoachMemory] {
        try await apiClient.get("/fitness/coach/memories",bypassCache: true)
    }

    func remember(_ candidate: FitnessCoachMemoryCandidate) async throws -> FitnessCoachMemory {
        try await apiClient.post(
            "/fitness/coach/memories",
            body: FitnessCoachMemoryCreate(
                id: UUID().uuidString,content: candidate.content,category: candidate.category
            )
        )
    }

    func updateMemory(
        id: String,content: String,category: String?
    ) async throws -> FitnessCoachMemory {
        try await apiClient.patch(
            "/fitness/coach/memories/\(id)",
            body: FitnessCoachMemoryUpdate(content: content,category: category)
        )
    }

    func forgetMemory(_ id: String) async throws {
        try await apiClient.delete("/fitness/coach/memories/\(id)")
    }

    func clearMemory() async throws -> FitnessCoachMemoryClearResult {
        try await apiClient.post("/fitness/coach/memory/clear")
    }

    func decide(
        proposalId: String,
        decision: FitnessCoachProposalAction
    ) async throws -> FitnessCoachProposalDecision {
        return try await apiClient.post(
            "/fitness/coach/proposals/\(proposalId)/\(decision.rawValue)"
        )
    }

    func undo(proposalId: String) async throws -> FitnessCoachProposalUndo {
        return try await apiClient.post("/fitness/coach/proposals/\(proposalId)/undo")
    }

    func recordFeedback(
        recommendationId: String,
        feedback: FitnessCoachFeedback
    ) async throws {
        try await apiClient.postNoResponse(
            "/fitness/coach/recommendations/\(recommendationId)/feedback",
            body: FitnessCoachFeedbackRequest(feedback: feedback)
        )
    }

    static func statusCode(_ error: Error) -> Int? {
        guard let error = error as? APIError else { return nil }
        if case .serverError(let statusCode,_) = error { return statusCode }
        return nil
    }
}

enum FitnessCoachProposalAction: String, Sendable { case confirm, decline }
