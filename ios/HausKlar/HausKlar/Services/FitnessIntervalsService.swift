import Foundation

protocol FitnessIntervalsServing: Sendable {
    func loadStatus() async throws -> FitnessIntervalsStatus
    func connect(apiKey: String) async throws -> FitnessIntervalsStatus
    func startOAuth() async throws -> FitnessIntervalsOAuthStart
    func testConnection() async throws -> FitnessIntervalsStatus
    func disconnect() async throws -> FitnessIntervalsDisconnectResult
    func updateActivityImport(enabled: Bool, lookbackDays: Int) async throws -> FitnessIntervalsStatus
    func syncActivities() async throws -> FitnessIntervalsActivityImportSync
    func loadDelivery(plannedSessionId: String) async throws -> FitnessIntervalsDelivery
    func send(plannedSessionId: String) async throws -> FitnessIntervalsDelivery
    func cancel(plannedSessionId: String) async throws -> FitnessIntervalsDelivery
}

actor FitnessIntervalsService: FitnessIntervalsServing {
    static let shared = FitnessIntervalsService()

    private let apiClient: APIClient
    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func loadStatus() async throws -> FitnessIntervalsStatus {
        try await apiClient.get("/fitness/integrations/intervals/status", bypassCache: true)
    }

    func connect(apiKey: String) async throws -> FitnessIntervalsStatus {
        try await apiClient.post(
            "/fitness/integrations/intervals/connect",
            body: FitnessIntervalsConnectRequest(apiKey: apiKey)
        )
    }

    func startOAuth() async throws -> FitnessIntervalsOAuthStart {
        try await apiClient.post(
            "/fitness/integrations/intervals/oauth/start",
            body: FitnessIntervalsOAuthStartRequest(returnSurface: "app")
        )
    }

    func testConnection() async throws -> FitnessIntervalsStatus {
        try await apiClient.post("/fitness/integrations/intervals/test")
    }

    func disconnect() async throws -> FitnessIntervalsDisconnectResult {
        try await apiClient.deleteReturning("/fitness/integrations/intervals")
    }

    func updateActivityImport(
        enabled: Bool,
        lookbackDays: Int = 30
    ) async throws -> FitnessIntervalsStatus {
        try await apiClient.put(
            "/fitness/integrations/intervals/activity-import",
            body: FitnessIntervalsActivityImportRequest(
                enabled: enabled,
                lookbackDays: lookbackDays
            )
        )
    }

    func syncActivities() async throws -> FitnessIntervalsActivityImportSync {
        try await apiClient.post("/fitness/integrations/intervals/activity-import/sync")
    }

    func loadDelivery(plannedSessionId: String) async throws -> FitnessIntervalsDelivery {
        try await apiClient.get(
            "/fitness/integrations/intervals/workouts/\(plannedSessionId)",
            bypassCache: true
        )
    }

    func send(plannedSessionId: String) async throws -> FitnessIntervalsDelivery {
        try await apiClient.post("/fitness/integrations/intervals/workouts/\(plannedSessionId)")
    }

    func cancel(plannedSessionId: String) async throws -> FitnessIntervalsDelivery {
        try await apiClient.deleteReturning(
            "/fitness/integrations/intervals/workouts/\(plannedSessionId)"
        )
    }
}

protocol FitnessStravaServing: Sendable {
    func loadStatus() async throws -> FitnessStravaStatus
    func startOAuth() async throws -> FitnessStravaOAuthStart
    func syncActivities() async throws -> FitnessStravaSync
    func disconnect() async throws -> FitnessStravaDisconnectResult
}

actor FitnessStravaService: FitnessStravaServing {
    static let shared = FitnessStravaService()

    private let apiClient: APIClient
    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func loadStatus() async throws -> FitnessStravaStatus {
        try await apiClient.get("/fitness/integrations/strava/status", bypassCache: true)
    }

    func startOAuth() async throws -> FitnessStravaOAuthStart {
        try await apiClient.post(
            "/fitness/integrations/strava/start",
            body: FitnessStravaOAuthStartRequest(returnSurface: "app")
        )
    }

    func syncActivities() async throws -> FitnessStravaSync {
        try await apiClient.post("/fitness/integrations/strava/sync")
    }

    func disconnect() async throws -> FitnessStravaDisconnectResult {
        try await apiClient.deleteReturning("/fitness/integrations/strava")
    }
}
