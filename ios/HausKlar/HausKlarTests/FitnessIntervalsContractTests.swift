import XCTest
@testable import HausKlar

final class FitnessIntervalsContractTests: XCTestCase {
    func testServiceUsesExactConnectionAndWorkoutDeliveryWireContract() async throws {
        let recorder = FitnessIntervalsRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body: String
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/fitness/integrations/intervals/status"),
                 ("POST", "/api/fitness/integrations/intervals/connect"),
                 ("POST", "/api/fitness/integrations/intervals/test"),
                 ("PUT", "/api/fitness/integrations/intervals/activity-import"):
                body = Self.connectedStatusJSON
            case ("POST", "/api/fitness/integrations/intervals/activity-import/sync"):
                body = Self.activitySyncJSON
            case ("POST", "/api/fitness/integrations/intervals/oauth/start"):
                body = #"{"authorization_url":"https://intervals.icu/oauth/authorize","expires_at":"2026-08-03T15:00:00Z"}"#
            case ("GET", "/api/fitness/integrations/intervals/workouts/session-1"):
                body = Self.pendingDeliveryJSON
            case ("POST", "/api/fitness/integrations/intervals/workouts/session-1"):
                body = Self.sentDeliveryJSON
            case ("DELETE", "/api/fitness/integrations/intervals/workouts/session-1"):
                body = Self.cancelledDeliveryJSON
            case ("DELETE", "/api/fitness/integrations/intervals"):
                body = #"{"status":"disconnected","retained_publication_count":1}"#
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(url.path)")
                body = #"{"detail":"Unexpected request"}"#
            }
            return (response, Data(body.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        defer { client.clearSession() }
        let service = FitnessIntervalsService(apiClient: client)

        let status = try await service.loadStatus()
        XCTAssertEqual(status.authMethod, .oauth)
        XCTAssertEqual(status.oauthScopes, ["CALENDAR:WRITE", "SETTINGS:READ", "ACTIVITY:READ"])
        XCTAssertEqual(status.garminTrainingConnected, false)
        _ = try await service.connect(apiKey:"secret-api-key")
        let oauth = try await service.startOAuth()
        XCTAssertEqual(oauth.authorizationUrl, "https://intervals.icu/oauth/authorize")
        _ = try await service.testConnection()
        _ = try await service.updateActivityImport(enabled:true,lookbackDays:30)
        let activitySync = try await service.syncActivities()
        XCTAssertEqual(activitySync.queuedCount, 1)
        let pending = try await service.loadDelivery(plannedSessionId:"session-1")
        XCTAssertEqual(pending.state, .pending)
        let sent = try await service.send(plannedSessionId:"session-1")
        XCTAssertEqual(sent.state, .sent)
        XCTAssertEqual(sent.pushErrors, ["Garmin upload is not enabled"])
        let cancelled = try await service.cancel(plannedSessionId:"session-1")
        XCTAssertEqual(cancelled.operation, .cancelled)
        let disconnected = try await service.disconnect()
        XCTAssertEqual(disconnected.retainedPublicationCount, 1)

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 10)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/api/fitness/integrations/intervals/status")
        let connectBody = try XCTUnwrap(requests[1].httpBody)
        let connectObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: connectBody) as? [String: String]
        )
        XCTAssertEqual(connectObject, ["api_key": "secret-api-key"])
        let oauthBody = try XCTUnwrap(requests[2].httpBody)
        let oauthObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: oauthBody) as? [String: String]
        )
        XCTAssertEqual(oauthObject, ["return_surface": "app"])
        XCTAssertNil(requests[3].httpBody)
        XCTAssertEqual(requests[4].httpMethod, "PUT")
        let importBody = try XCTUnwrap(requests[4].httpBody)
        let importObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: importBody) as? [String: Any]
        )
        XCTAssertEqual(importObject["enabled"] as? Bool, true)
        XCTAssertEqual(importObject["lookback_days"] as? Int, 30)
        XCTAssertEqual(requests[5].url?.path, "/api/fitness/integrations/intervals/activity-import/sync")
        XCTAssertEqual(requests[6].httpMethod, "GET")
        XCTAssertEqual(requests[7].httpMethod, "POST")
        XCTAssertEqual(requests[8].httpMethod, "DELETE")
        XCTAssertEqual(requests[9].url?.path, "/api/fitness/integrations/intervals")
    }

    @MainActor
    func testViewModelClearsConnectionAndDeliveryStateWhenOwnerChanges() async {
        let service = FitnessIntervalsServiceStub()
        var owner = FitnessIntervalsOwnerContext(identity: "family-a:user-a", generation: 1)
        let viewModel = FitnessIntervalsViewModel(
            service: service,
            ownerContextProvider: { owner }
        )
        var plan = FitnessPlannedSession(
            id: "session-1",
            title: "Tempo run",
            plannedFor: Date(),
            exerciseIds: [],
            isCompleted: false,
            revision: 1,
            updatedAt: Date()
        )
        plan.status = "accepted"
        plan.sportKey = "running"
        plan.workoutVersionId = "workout-version-1"

        await viewModel.load()
        await viewModel.send(plan)
        XCTAssertEqual(viewModel.delivery(for: plan.id)?.state, .sent)
        XCTAssertEqual(viewModel.operationMessage, "Sent to Intervals.icu")

        owner = FitnessIntervalsOwnerContext(identity: "family-b:user-b", generation: 2)
        await viewModel.load()

        XCTAssertTrue(viewModel.isConnected)
        XCTAssertNil(viewModel.delivery(for: plan.id))
        XCTAssertNil(viewModel.operationMessage)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testOnlyAcceptedScheduledRunPlansAreDeliveryEligible() {
        var plan = FitnessPlannedSession(
            id: "session-1",
            title: "Tempo run",
            plannedFor: Date(),
            exerciseIds: [],
            isCompleted: false,
            revision: 1,
            updatedAt: Date()
        )
        plan.status = "accepted"
        plan.sportKey = "running"
        plan.workoutVersionId = "workout-version-1"
        XCTAssertTrue(plan.isIntervalsDeliveryEligible)

        plan.status = "proposed"
        XCTAssertFalse(plan.isIntervalsDeliveryEligible)
        plan.status = "scheduled"
        plan.sportKey = "strength"
        XCTAssertFalse(plan.isIntervalsDeliveryEligible)
        plan.sportKey = "running"
        plan.isCompleted = true
        XCTAssertFalse(plan.isIntervalsDeliveryEligible)
    }

    func testProviderDownStravaStatusDecodesAsConnectedIntegration() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(
            FitnessStravaStatus.self,
            from: Data(Self.providerDownStravaStatusJSON.utf8)
        )

        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.status, .providerDown)
        XCTAssertTrue(status.isConnectedIntegration)
        XCTAssertEqual(status.athleteName, "Reviewer Runner")
        XCTAssertEqual(status.lastErrorCode, "provider_unavailable")
    }

    @MainActor
    func testProviderDownStravaConnectionCanRetryAndRecover() async {
        let service = FitnessStravaServiceStub()
        let owner = FitnessIntervalsOwnerContext(identity: "family-a:user-a", generation: 1)
        let viewModel = FitnessStravaViewModel(
            service: service,
            ownerContextProvider: { owner }
        )

        await viewModel.load()
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertEqual(viewModel.status?.status, .providerDown)

        let changed = await viewModel.syncActivities()
        let syncInvocations = await service.syncInvocationCount()

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(syncInvocations, 1)
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertEqual(viewModel.status?.status, .connected)
        XCTAssertEqual(viewModel.operationMessage, "1 session brought in from Strava.")
    }

    private static let connectedStatusJSON = #"""
    {
      "configured":true,"oauth_available":true,"personal_api_key_available":true,
      "connected":true,"status":"connected","auth_method":"oauth",
      "oauth_scopes":["CALENDAR:WRITE","SETTINGS:READ","ACTIVITY:READ"],
      "athlete_id":"i123","athlete_name":"Reviewer Athlete","garmin_training_connected":false,
      "last_tested_at":"2026-08-03T14:00:00Z","last_error_code":null,
      "activity_read_authorized":true,"activity_import_enabled":true,
      "activity_import_since":"2026-07-04T14:00:00Z",
      "last_activity_import_at":"2026-08-03T14:00:00Z",
      "last_activity_import_error_code":null,"activity_imported_count":2,
      "activity_import_pending_count":1,"activity_import_error_count":0
    }
    """#

    private static let activitySyncJSON = #"""
    {
      "discovered_count":3,"queued_count":1,"existing_count":2,"skipped_count":0,
      "status":\#(connectedStatusJSON)
    }
    """#

    private static let pendingDeliveryJSON = #"""
    {
      "planned_session_id":"session-1","state":"pending","operation":"updated",
      "external_id":"hausklar-session-1","provider_event_id":"event-1","sent_at":null,
      "last_error_code":null,"push_errors":[]
    }
    """#

    private static let sentDeliveryJSON = #"""
    {
      "planned_session_id":"session-1","state":"sent","operation":"created",
      "external_id":"hausklar-session-1","provider_event_id":"event-1",
      "sent_at":"2026-08-03T14:01:00Z","last_error_code":null,
      "push_errors":["Garmin upload is not enabled"]
    }
    """#

    private static let cancelledDeliveryJSON = #"""
    {
      "planned_session_id":"session-1","state":"cancelled","operation":"cancelled",
      "external_id":"hausklar-session-1","provider_event_id":"event-1",
      "sent_at":"2026-08-03T14:01:00Z","last_error_code":null,"push_errors":[]
    }
    """#

    private static let providerDownStravaStatusJSON = #"""
    {
      "configured":true,"connected":true,"status":"provider_down",
      "athlete_name":"Reviewer Runner","last_sync_at":"2026-08-09T07:00:00Z",
      "data_through_at":"2026-08-08T06:00:00Z","imported_activity_count":12,
      "last_error_code":"provider_unavailable"
    }
    """#
}

private final class FitnessIntervalsRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        var captured=request
        if captured.httpBody == nil,let stream=captured.httpBodyStream,
           let body=Self.read(stream) {
            captured.httpBody=body
        }
        lock.withLock { storage.append(captured) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    private static func read(_ stream:InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data=Data()
        var buffer=[UInt8](repeating:0,count:1_024)
        while stream.hasBytesAvailable {
            let count=stream.read(&buffer,maxLength:buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer,count:count)
        }
        return data
    }
}

private actor FitnessIntervalsServiceStub: FitnessIntervalsServing {
    func loadStatus() async throws -> FitnessIntervalsStatus {
        FitnessIntervalsStatus(
            configured: true,
            oauthAvailable: true,
            personalApiKeyAvailable: true,
            connected: true,
            status: .connected,
            authMethod: .oauth,
            oauthScopes: ["CALENDAR:WRITE", "SETTINGS:READ", "ACTIVITY:READ"],
            athleteId: "athlete",
            athleteName: "Reviewer Athlete",
            garminTrainingConnected: true,
            lastTestedAt: "2026-08-03T14:00:00Z",
            lastErrorCode: nil,
            activityReadAuthorized: true,
            activityImportEnabled: false,
            activityImportSince: nil,
            lastActivityImportAt: nil,
            lastActivityImportErrorCode: nil,
            activityImportedCount: 0,
            activityImportPendingCount: 0,
            activityImportErrorCount: 0
        )
    }

    func connect(apiKey: String) async throws -> FitnessIntervalsStatus { try await loadStatus() }
    func startOAuth() async throws -> FitnessIntervalsOAuthStart {
        FitnessIntervalsOAuthStart(
            authorizationUrl: "https://intervals.icu/oauth/authorize",
            expiresAt: "2026-08-03T15:00:00Z"
        )
    }
    func testConnection() async throws -> FitnessIntervalsStatus { try await loadStatus() }
    func disconnect() async throws -> FitnessIntervalsDisconnectResult {
        FitnessIntervalsDisconnectResult(status: .disconnected, retainedPublicationCount: 1)
    }
    func updateActivityImport(enabled: Bool, lookbackDays: Int) async throws -> FitnessIntervalsStatus {
        try await loadStatus()
    }
    func syncActivities() async throws -> FitnessIntervalsActivityImportSync {
        FitnessIntervalsActivityImportSync(
            discoveredCount: 1,
            queuedCount: 1,
            existingCount: 0,
            skippedCount: 0,
            status: try await loadStatus()
        )
    }
    func loadDelivery(plannedSessionId: String) async throws -> FitnessIntervalsDelivery {
        delivery(plannedSessionId: plannedSessionId, state: .notSent, operation: .none)
    }
    func send(plannedSessionId: String) async throws -> FitnessIntervalsDelivery {
        delivery(plannedSessionId: plannedSessionId, state: .sent, operation: .created)
    }
    func cancel(plannedSessionId: String) async throws -> FitnessIntervalsDelivery {
        delivery(plannedSessionId: plannedSessionId, state: .cancelled, operation: .cancelled)
    }

    private func delivery(
        plannedSessionId: String,
        state: FitnessIntervalsDeliveryState,
        operation: FitnessIntervalsDeliveryOperation
    ) -> FitnessIntervalsDelivery {
        FitnessIntervalsDelivery(
            plannedSessionId: plannedSessionId,
            state: state,
            operation: operation,
            externalId: "hausklar-\(plannedSessionId)",
            providerEventId: "event-1",
            sentAt: state == .sent ? "2026-08-03T14:01:00Z" : nil,
            lastErrorCode: nil,
            pushErrors: []
        )
    }
}

private actor FitnessStravaServiceStub: FitnessStravaServing {
    private var syncCalls = 0

    func loadStatus() async throws -> FitnessStravaStatus {
        providerDownStatus
    }

    func startOAuth() async throws -> FitnessStravaOAuthStart {
        FitnessStravaOAuthStart(
            authorizationUrl: "https://www.strava.com/oauth/authorize",
            expiresAt: "2026-08-10T15:00:00Z"
        )
    }

    func syncActivities() async throws -> FitnessStravaSync {
        syncCalls += 1
        return FitnessStravaSync(
            importedCount: 1,
            updatedCount: 0,
            unchangedCount: 0,
            latestActivity: nil,
            status: connectedStatus
        )
    }

    func disconnect() async throws -> FitnessStravaDisconnectResult {
        FitnessStravaDisconnectResult(status: .disconnected, retainedActivityCount: 12)
    }

    func syncInvocationCount() -> Int {
        syncCalls
    }

    private var providerDownStatus: FitnessStravaStatus {
        FitnessStravaStatus(
            configured: true,
            connected: true,
            status: .providerDown,
            athleteName: "Reviewer Runner",
            lastSyncAt: "2026-08-09T07:00:00Z",
            dataThroughAt: "2026-08-08T06:00:00Z",
            importedActivityCount: 12,
            lastErrorCode: "provider_unavailable"
        )
    }

    private var connectedStatus: FitnessStravaStatus {
        FitnessStravaStatus(
            configured: true,
            connected: true,
            status: .connected,
            athleteName: "Reviewer Runner",
            lastSyncAt: "2026-08-10T07:00:00Z",
            dataThroughAt: "2026-08-10T06:00:00Z",
            importedActivityCount: 13,
            lastErrorCode: nil
        )
    }
}
