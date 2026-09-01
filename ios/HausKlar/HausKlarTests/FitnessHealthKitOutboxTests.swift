import Foundation
import GRDB
import XCTest

@testable import HausKlar

final class FitnessHealthKitOutboxTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!
    private var database: FitnessDatabase!
    private var repository: FitnessHealthRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitnessHealthOutboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("a/fitness.sqlite")
        database = FitnessDatabase()
        try database.activateForTesting(identity: "family-a:user-a", storeURL: storeURL)
        repository = FitnessHealthRepository(database: database, clientId: "test-client")
    }

    override func tearDownWithError() throws {
        HealthKitOutboxURLProtocol.reset()
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMoreThanFiveHundredWorkoutsStageAcrossPagesWithoutLosingEitherAnchor() async throws {
        let firstPage = (0..<500).map { workoutRequest(index: $0) }
        let final = workoutRequest(index: 500)

        try await repository.stageWorkoutHealthKitPage(
            requests: firstPage, deletedWorkoutUuids: [], archivedAnchor: Data([1])
        )
        try await repository.stageWorkoutHealthKitPage(
            requests: [final], deletedWorkoutUuids: [], archivedAnchor: Data([2])
        )

        let result = try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_healthkit_workout_outbox") ?? 0,
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(DISTINCT mutation_id) FROM fitness_healthkit_workout_outbox"
                ) ?? 0,
                try Data.fetchOne(
                    db,
                    sql: "SELECT anchor_data FROM fitness_healthkit_query_state WHERE sample_type=?",
                    arguments: [FitnessHealthKitSampleKind.workout.rawValue]
                )
            )
        }
        XCTAssertEqual(result.0, 501)
        XCTAssertEqual(result.1, 501)
        XCTAssertEqual(result.2, Data([2]))
        XCTAssertEqual(FitnessHealthKitPagingPolicy.anchoredPageSize, 500)
        XCTAssertTrue(FitnessHealthKitPagingPolicy.hasMore(sampleCount: 500, deletionCount: 0))
        XCTAssertFalse(FitnessHealthKitPagingPolicy.hasMore(sampleCount: 499, deletionCount: 0))
        XCTAssertEqual(
            FitnessHealthKitWorkoutOutboxPolicy.maximumRecords(forReplayTurns: 20), 500
        )
    }

    func testLaterPageLocalFailureLeavesEarlierPageAndAnchorAuthoritative() async throws {
        try await repository.stageWorkoutHealthKitPage(
            requests: (0..<500).map { workoutRequest(index: $0) },
            deletedWorkoutUuids: [], archivedAnchor: Data([1])
        )
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_second_workout_page
                    BEFORE INSERT ON fitness_healthkit_workout_outbox
                    BEGIN SELECT RAISE(ABORT,'injected second page failure'); END;
                    """)
        }

        do {
            try await repository.stageWorkoutHealthKitPage(
                requests: [workoutRequest(index: 500)],
                deletedWorkoutUuids: [], archivedAnchor: Data([2])
            )
            XCTFail("The injected second-page failure should abort its anchor transaction")
        } catch {}

        let result = try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_healthkit_workout_outbox") ?? 0,
                try Data.fetchOne(
                    db,
                    sql: "SELECT anchor_data FROM fitness_healthkit_query_state WHERE sample_type=?",
                    arguments: [FitnessHealthKitSampleKind.workout.rawValue]
                )
            )
        }
        XCTAssertEqual(result.0, 500)
        XCTAssertEqual(result.1, Data([1]))
    }

    func testServerSuccessThenLocalAcknowledgementFailureReplaysSameStableSourceIdentity() async throws {
        let request = workoutRequest(index: 1)
        try await repository.stageWorkoutHealthKitPage(
            requests: [request], deletedWorkoutUuids: [], archivedAnchor: Data([1])
        )
        let pending = try await repository.pendingWorkoutImports()
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(item.id, FitnessHealthRepository.workoutMutationID(request: request))
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_workout_receipt
                    BEFORE DELETE ON fitness_healthkit_workout_outbox
                    BEGIN SELECT RAISE(ABORT,'injected receipt failure'); END;
                    """)
        }
        let response = FitnessHealthKitWorkoutImportResponse(
            status: "created", sourceRecordId: "source-1", activityId: "activity-1", deleted: false
        )

        do {
            try await repository.acknowledgeWorkoutImport(
                itemId: item.id, request: request, response: response
            )
            XCTFail("Source receipt and replay removal must be one transaction")
        } catch {}
        let retainedIds = try await repository.pendingWorkoutImports().map(\.id)
        let failedSources = try await repository.workoutSources(workoutUuid: request.workoutUuid)
        XCTAssertEqual(retainedIds, [item.id])
        XCTAssertTrue(failedSources.isEmpty)

        try database.write { db in try db.execute(sql: "DROP TRIGGER reject_workout_receipt") }
        try await repository.acknowledgeWorkoutImport(
            itemId: item.id, request: request,
            response: .init(
                status: "unchanged", sourceRecordId: "source-1",
                activityId: "activity-1", deleted: false
            )
        )
        let remaining = try await repository.pendingWorkoutImports()
        let acknowledgedSources = try await repository.workoutSources(workoutUuid: request.workoutUuid)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(acknowledgedSources.first?.sourceBundleIdentifier, request.sourceBundleIdentifier)
    }

    func testCrashRestartRetainsStagedPageAnchorAndPayload() async throws {
        let request = workoutRequest(index: 4)
        try await repository.stageWorkoutHealthKitPage(
            requests: [request], deletedWorkoutUuids: [], archivedAnchor: Data([4])
        )
        let staged = try await repository.pendingWorkoutImports()
        let originalId = try XCTUnwrap(staged.first?.id)
        database.suspend()

        let reopened = FitnessDatabase()
        try reopened.activateForTesting(identity: "family-a:user-a", storeURL: storeURL)
        let reopenedRepository = FitnessHealthRepository(database: reopened, clientId: "test-client")
        let restored = try await reopenedRepository.pendingWorkoutImports()
        let restoredAnchor = try await reopenedRepository.anchorState(kind: .workout)
        XCTAssertEqual(restored.map(\.id), [originalId])
        XCTAssertEqual(restored.first?.request, request)
        XCTAssertEqual(restoredAnchor.anchorData, Data([4]))
        reopened.suspend()
    }

    func testActivationResumesDurableReplayWithoutRequeryingHealthKit() async throws {
        let request = workoutRequest(index: 6)
        try await repository.stageWorkoutHealthKitPage(
            requests: [request], deletedWorkoutUuids: [], archivedAnchor: Data([6])
        )
        let requestStarted = expectation(description: "scheduled replay reached transport")
        let activationReturned = expectation(description: "activation did not await replay")
        let releaseResponse = DispatchSemaphore(value: 0)
        HealthKitOutboxURLProtocol.install { urlRequest in
            XCTAssertEqual(urlRequest.httpMethod, "POST")
            XCTAssertTrue(urlRequest.url?.path.hasSuffix("/fitness/imports/healthkit-workout") == true)
            requestStarted.fulfill()
            guard releaseResponse.wait(timeout: .now() + 5) == .success else {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(urlRequest.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(#"{"status":"created","source_record_id":"source-6","activity_id":"activity-6","deleted":false}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthKitOutboxURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://healthkit-outbox-\(UUID().uuidString).example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a", accessToken: "access", refreshToken: "refresh"
        )
        let service = FitnessHealthKitService(
            repository: repository, apiClient: client, database: database
        )

        let activation = Task {
            await service.activate(identity: "family-a:user-a")
            activationReturned.fulfill()
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        await fulfillment(of: [activationReturned], timeout: 1)
        releaseResponse.signal()
        await activation.value
        // Activation schedules replay so observer setup is never network-bound;
        // the explicit drain API is used only by this test to join that task.
        await service.flushPendingWorkoutImports(maximumTurns: 1)

        let pending = try await repository.pendingWorkoutImports()
        let source = try await repository.workoutSources(workoutUuid: request.workoutUuid)
        let anchor = try await repository.anchorState(kind: .workout)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(source.first?.sourceBundleIdentifier, request.sourceBundleIdentifier)
        XCTAssertEqual(anchor.anchorData, Data([6]))
        await service.suspend()
        client.clearSession()
    }

    func testDeletionAndAnchorStageBeforeRemoteSourceResolution() async throws {
        let workoutUuid = UUID().uuidString
        try await repository.stageWorkoutHealthKitPage(
            requests: [], deletedWorkoutUuids: [workoutUuid], archivedAnchor: Data([8])
        )
        let staged = try await repository.pendingWorkoutImports()
        var item = try XCTUnwrap(staged.first)
        XCTAssertEqual(item.kind, .resolveDelete)
        XCTAssertNil(item.request)
        let stagedAnchor = try await repository.anchorState(kind: .workout)
        XCTAssertEqual(stagedAnchor.anchorData, Data([8]))

        try await repository.resolveWorkoutDeletion(
            itemId: item.id, workoutUuid: workoutUuid,
            sources: [
                FitnessHealthKitWorkoutSource(
                    workoutUuid: workoutUuid, sourceBundleIdentifier: "com.apple.health",
                    originProviderKey: "apple", externalUuid: nil, sourceName: "Apple Health",
                    sourceDeviceIdentifier: nil, productType: nil
                )
            ]
        )
        let resolved = try await repository.pendingWorkoutImports()
        item = try XCTUnwrap(resolved.first)
        XCTAssertEqual(item.kind, .import)
        XCTAssertEqual(item.request?.deleted, true)
        XCTAssertEqual(item.request?.workoutUuid, workoutUuid)
    }

    func testStaleOwnerLeaseCannotAcknowledgeIntoReplacementStore() async throws {
        database.suspend()
        try database.activateForTesting(
            identity: "family-a:user-a", storeURL: storeURL, requiresLease: true
        )
        let leaseA = try database.lease(for: "family-a:user-a")
        let request = workoutRequest(index: 9)
        try await database.withLease(leaseA) {
            try await repository.stageWorkoutHealthKitPage(
                requests: [request], deletedWorkoutUuids: [], archivedAnchor: Data([9])
            )
        }
        let item = try await database.withLease(leaseA) {
            let pending = try await repository.pendingWorkoutImports()
            return try XCTUnwrap(pending.first)
        }

        database.suspend()
        let bURL = directory.appendingPathComponent("b/fitness.sqlite")
        try database.activateForTesting(
            identity: "family-a:user-b", storeURL: bURL, requiresLease: true
        )
        let leaseB = try database.lease(for: "family-a:user-b")
        do {
            try await database.withLease(leaseA) {
                try await repository.acknowledgeWorkoutImport(
                    itemId: item.id, request: request,
                    response: .init(
                        status: "created", sourceRecordId: "source-a",
                        activityId: "activity-a", deleted: false
                    )
                )
            }
            XCTFail("An account-A lease must be invalid after account B replaces it")
        } catch FitnessDatabaseError.staleLease {}
        let bStatus = try await database.withLease(leaseB) {
            try await repository.workoutOutboxStatus()
        }
        XCTAssertEqual(bStatus.pendingCount, 0)

        database.suspend()
        try database.activateForTesting(
            identity: "family-a:user-a", storeURL: storeURL, requiresLease: true
        )
        let restoredLeaseA = try database.lease(for: "family-a:user-a")
        let restoredIds = try await database.withLease(restoredLeaseA) {
            try await repository.pendingWorkoutImports().map(\.id)
        }
        XCTAssertEqual(restoredIds, [item.id])
    }

    func testSuspendCancelsAndJoinsBlockedReplayBeforeAccountReplacement() async throws {
        let request = workoutRequest(index: 10)
        try await repository.stageWorkoutHealthKitPage(
            requests: [request], deletedWorkoutUuids: [], archivedAnchor: Data([10])
        )
        let requestStarted = expectation(description: "account A request started")
        let activationReturned = expectation(description: "account A activation returned")
        let lateTransportFinished = expectation(
            description: "cancelled URLProtocol finished its deliberately late callback"
        )
        let releaseResponse = DispatchSemaphore(value: 0)
        HealthKitOutboxURLProtocol.install(
            { urlRequest in
                requestStarted.fulfill()
                guard releaseResponse.wait(timeout: .now() + 5) == .success else {
                    throw URLError(.timedOut)
                }
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(urlRequest.url), statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (
                    response,
                    Data(#"{"status":"created","source_record_id":"late-a","activity_id":"late-activity-a","deleted":false}"#.utf8)
                )
            },
            loadingFinished: { lateTransportFinished.fulfill() }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthKitOutboxURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://healthkit-replacement-\(UUID().uuidString).example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a", accessToken: "access-a", refreshToken: "refresh-a"
        )
        let service = FitnessHealthKitService(
            repository: repository, apiClient: client, database: database
        )
        let activation = Task {
            await service.activate(identity: "family-a:user-a")
            activationReturned.fulfill()
        }
        await fulfillment(of: [requestStarted, activationReturned], timeout: 2)
        await activation.value

        let suspensionReturned = expectation(
            description: "suspend joined the cancelled account-A replay"
        )
        let suspension = Task {
            await service.suspend()
            suspensionReturned.fulfill()
        }
        // URLSession cancellation completes the app-owned request at its
        // terminal delegate callback. It does not promise to keep `suspend()`
        // blocked until an intentionally uncooperative URLProtocol returns from
        // `startLoading`; that old assertion tested a Foundation implementation
        // detail rather than HausKlar's task ownership.
        await fulfillment(of: [suspensionReturned], timeout: 2)
        await suspension.value

        let retainedBeforeLateCallback = try await repository.pendingWorkoutImports()
        let sourcesBeforeLateCallback = try await repository.workoutSources(
            workoutUuid: request.workoutUuid
        )
        XCTAssertEqual(retainedBeforeLateCallback.compactMap(\.request), [request])
        XCTAssertTrue(sourcesBeforeLateCallback.isEmpty)

        releaseResponse.signal()
        await fulfillment(of: [lateTransportFinished], timeout: 2)

        let retainedA = try await repository.pendingWorkoutImports()
        let lateSourcesA = try await repository.workoutSources(workoutUuid: request.workoutUuid)
        XCTAssertEqual(retainedA.compactMap(\.request), [request])
        XCTAssertTrue(lateSourcesA.isEmpty, "A late response must not publish a local receipt")

        database.suspend()
        let bURL = directory.appendingPathComponent("replacement-b/fitness.sqlite")
        try database.activateForTesting(identity: "family-a:user-b", storeURL: bURL)
        _ = client.installSession(
            identity: "family-a:user-b", accessToken: "access-b", refreshToken: "refresh-b"
        )
        await service.activate(identity: "family-a:user-b")
        let bStatus = try await repository.workoutOutboxStatus()
        XCTAssertEqual(bStatus.pendingCount, 0)
        await service.suspend()
        client.clearSession()

        database.suspend()
        try database.activateForTesting(identity: "family-a:user-a", storeURL: storeURL)
        let restoredA = try await repository.pendingWorkoutImports()
        XCTAssertEqual(restoredA.compactMap(\.request), [request])
    }

    func testRowCapacityFailsClosedWithoutAdvancingAnchor() async throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            for index in 0..<FitnessHealthKitWorkoutOutboxPolicy.maximumRows {
                let workoutUuid = deterministicUUID(index: index + 20_000)
                try db.execute(
                    sql: """
                        INSERT INTO fitness_healthkit_workout_outbox
                        (mutation_id,mutation_kind,workout_uuid,source_bundle_identifier,
                         payload_json,payload_byte_count,state,attempt_count,created_at,updated_at)
                        VALUES (?,'resolve_delete',?,NULL,'{}',2,'pending',0,?,?)
                        """,
                    arguments: [
                        FitnessHealthRepository.workoutResolverMutationID(workoutUuid: workoutUuid),
                        workoutUuid, now, now,
                    ]
                )
            }
        }
        do {
            try await repository.stageWorkoutHealthKitPage(
                requests: [workoutRequest(index: 12)],
                deletedWorkoutUuids: [], archivedAnchor: Data([12])
            )
            XCTFail("A saturated durable queue must refuse the page and its cursor")
        } catch FitnessHealthRepositoryError.healthKitWorkoutOutboxFull {}
        let anchor = try await repository.anchorState(kind: .workout)
        let status = try await repository.workoutOutboxStatus()
        XCTAssertNil(anchor.anchorData)
        XCTAssertEqual(status.pendingCount, FitnessHealthKitWorkoutOutboxPolicy.maximumRows)
    }

    func testByteCapacityFailsClosedWithoutAdvancingAnchor() async throws {
        let now = FitnessDatabase.dateString(Date())
        let workoutUuid = deterministicUUID(index: 40_000)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_healthkit_workout_outbox
                    (mutation_id,mutation_kind,workout_uuid,source_bundle_identifier,
                     payload_json,payload_byte_count,state,attempt_count,created_at,updated_at)
                    VALUES (?,'resolve_delete',?,NULL,'{}',?,'pending',0,?,?)
                    """,
                arguments: [
                    FitnessHealthRepository.workoutResolverMutationID(workoutUuid: workoutUuid),
                    workoutUuid, FitnessHealthKitWorkoutOutboxPolicy.maximumBytes, now, now,
                ]
            )
        }
        do {
            try await repository.stageWorkoutHealthKitPage(
                requests: [workoutRequest(index: 13)],
                deletedWorkoutUuids: [], archivedAnchor: Data([13])
            )
            XCTFail("A byte-saturated queue must refuse the page and its cursor")
        } catch FitnessHealthRepositoryError.healthKitWorkoutOutboxFull {}
        let anchor = try await repository.anchorState(kind: .workout)
        let status = try await repository.workoutOutboxStatus()
        XCTAssertNil(anchor.anchorData)
        XCTAssertEqual(status.payloadBytes, FitnessHealthKitWorkoutOutboxPolicy.maximumBytes)
    }

    func testReplayClassifiesContractFailuresWithoutRetryingAuthenticationOrTransport() {
        XCTAssertTrue(FitnessHealthKitService.isPermanentWorkoutRejection(APIError.forbidden))
        XCTAssertTrue(
            FitnessHealthKitService.isPermanentWorkoutRejection(
                APIError.decodingError(CocoaError(.propertyListReadCorrupt))
            )
        )
        XCTAssertTrue(
            FitnessHealthKitService.isPermanentWorkoutRejection(
                FitnessHealthRepositoryError.invalidWorkoutAcknowledgement
            )
        )
        XCTAssertFalse(FitnessHealthKitService.isPermanentWorkoutRejection(APIError.unauthorized))
        XCTAssertFalse(
            FitnessHealthKitService.isPermanentWorkoutRejection(
                APIError.networkError(URLError(.notConnectedToInternet))
            )
        )
        for statusCode in [408, 425, 429] {
            XCTAssertFalse(
                FitnessHealthKitService.isPermanentWorkoutRejection(
                    APIError.serverError(statusCode: statusCode, message: nil)
                )
            )
        }
    }

    private func workoutRequest(index: Int) -> FitnessHealthKitWorkoutImport {
        FitnessHealthKitWorkoutImport(
            sourceBundleIdentifier: "com.apple.health", workoutUuid: deterministicUUID(index: index),
            originProviderKey: "apple", externalUuid: "external-\(index)", sourceName: "Apple Watch",
            sourceDeviceIdentifier: "watch", productType: "Watch7,1", sportKey: "running",
            subSportKey: nil, title: "Run", startedAtUtc: "2026-08-03T08:00:00.000Z",
            endedAtUtc: "2026-08-03T08:30:00.000Z", durationS: 1_800, distanceM: 5_000,
            energyKcal: 350, localTimezone: "Europe/London", deleted: false
        )
    }

    private func deterministicUUID(index: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", index)
    }
}

private final class HealthKitOutboxURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private struct Fixture {
        let handler: Handler
        let loadingFinished: (() -> Void)?
    }

    /// URLProtocol calls this fixture from Foundation-owned threads. The lock
    /// makes install/snapshot/reset atomic; each request keeps its immutable
    /// snapshot even when teardown clears the next request's fixture.
    private final class FixtureStore: @unchecked Sendable {
        private let lock = NSLock()
        private var fixture: Fixture?

        func install(_ fixture: Fixture) {
            lock.withLock { self.fixture = fixture }
        }

        func snapshot() -> Fixture? {
            lock.withLock { fixture }
        }

        func reset() {
            lock.withLock { fixture = nil }
        }
    }

    private static let fixtures = FixtureStore()

    static func install(
        _ handler: @escaping Handler,
        loadingFinished: (() -> Void)? = nil
    ) {
        fixtures.install(Fixture(handler: handler, loadingFinished: loadingFinished))
    }

    static func reset() {
        fixtures.reset()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.fixtures.snapshot() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        defer { fixture.loadingFinished?() }
        do {
            let (response, data) = try fixture.handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    // Intentionally uncooperative: the account-replacement regression must
    // prove that even a callback produced after cancellation has no authority.
    override func stopLoading() {}
}
