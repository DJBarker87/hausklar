import XCTest
import SwiftData
@testable import HausKlar

private enum SyncRequestBodyCaptureError: LocalizedError {
    case missingBody
    case readFailed(String)
    case bodyTooLarge(maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case .missingBody:
            "The intercepted sync request did not contain a body."
        case .readFailed(let detail):
            "The intercepted sync request body could not be read: \(detail)"
        case .bodyTooLarge(let maximumBytes):
            "The intercepted sync request body exceeded \(maximumBytes) bytes."
        }
    }
}

/// URLSession may expose a data-backed request as a body stream by the time a
/// custom URLProtocol intercepts it. Consume that stream once at the transport
/// edge and enforce a finite cap before decoding exact sync payloads.
private func syncRequestBodyData(
    _ request: URLRequest,
    maximumBytes: Int = 1_048_576
) throws -> Data {
    guard maximumBytes > 0 else {
        throw SyncRequestBodyCaptureError.bodyTooLarge(maximumBytes: maximumBytes)
    }
    if let body = request.httpBody {
        guard body.count <= maximumBytes else {
            throw SyncRequestBodyCaptureError.bodyTooLarge(maximumBytes: maximumBytes)
        }
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw SyncRequestBodyCaptureError.missingBody
    }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 8_192)
    while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw SyncRequestBodyCaptureError.readFailed(
                stream.streamError?.localizedDescription ?? "Unknown stream error."
            )
        }
        if count == 0 { return body }
        guard count <= maximumBytes, body.count <= maximumBytes - count else {
            throw SyncRequestBodyCaptureError.bodyTooLarge(maximumBytes: maximumBytes)
        }
        body.append(buffer, count: count)
    }
}

/// Tests for the SyncManager offline queue.
///
/// Uses an in-memory SwiftData ModelContainer so tests are fast, isolated,
/// and do not touch any persistent store.
@MainActor
final class SyncManagerTests: XCTestCase {

    private var syncManager: SyncManager!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() {
        super.setUp()
        syncManager = SyncManager()
        syncManager.activate(identity: "test-family:test-user")
        SyncManager.shared.activate(identity: "test-family:test-user")

        // MedicineViewModel loads and persists its local safety cache as soon as
        // a ModelContext is bound. Keep the test store aligned with every model
        // touched by that path; asking SwiftData for models absent from the
        // container corrupts XCTest's async error-observation task on iOS 17.5.
        let schema = Schema([
            OfflineAction.self,
            MedicineType.self,
            MedicineDose.self,
            Child.self,
            Nap.self,
            FamilyTask.self,
            CalendarEvent.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        syncManager = nil
        container = nil
        context = nil
        super.tearDown()
    }

    private func makeStubbedSyncManager(
        now: @escaping () -> Date = Date.init,
        retryJitter: @escaping () -> Double = { 1 },
        saveQueueContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> (manager: SyncManager, client: APIClient, defaults: UserDefaults, suiteName: String) {
        APIClientStubURLProtocol.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://sync.example.test/api"
        _ = client.installSession(
            identity: "sync-tests:\(UUID().uuidString)",
            accessToken: "test-access",
            refreshToken: "test-refresh"
        )
        let suiteName = "SyncManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let manager = SyncManager(
            client: client,
            defaults: defaults,
            now: now,
            retryJitter: retryJitter,
            saveQueueContext: saveQueueContext
        )
        manager.activate(identity: "test-family:test-user")
        return (manager, client, defaults, suiteName)
    }

    private func jsonResponse(
        for request: URLRequest,
        statusCode: Int = 200,
        body: String
    ) throws -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private func taskDTO(
        id: String,
        title: String,
        category: String = "other",
        createdBy: String? = nil,
        assignedTo: String? = nil,
        dueDate: String? = nil,
        recurrenceRule: String? = nil,
        completedAt: String? = nil,
        actionableFrom: String? = nil,
        priority: Int = 2,
        assignees: [TaskAssigneeDTO] = [],
        sourceDocumentId: String? = nil,
        sourceDocument: SourceDocumentDTO? = nil,
        readOnly: Bool = false,
        managedSource: ManagedSourceDTO? = nil
    ) -> TaskDTO {
        let timestamp = "2026-07-14T12:00:00Z"
        return TaskDTO(
            id: id,
            title: title,
            description: nil,
            assignedTo: assignedTo,
            dueDate: dueDate,
            completedAt: completedAt,
            category: category,
            recurrenceRule: recurrenceRule,
            priority: priority,
            createdAt: timestamp,
            updatedAt: timestamp,
            createdBy: createdBy,
            actionableFrom: actionableFrom,
            assignees: assignees,
            sourceDocumentId: sourceDocumentId ?? sourceDocument?.id,
            sourceDocument: sourceDocument,
            readOnly: readOnly,
            managedSource: managedSource
        )
    }

    private func sourceDocument(id: String = "document-1") -> SourceDocumentDTO {
        SourceDocumentDTO(
            id: id,
            title: "School letter",
            originalFilename: "school-letter.pdf",
            mediaType: "application/pdf",
            fileSize: 24_000,
            downloadUrl: "/api/documents/\(id)/content"
        )
    }

    // MARK: - Queue creation

    func testQueueOfflineActionCreatesRecord() {
        syncManager.queueOfflineAction(
            modelContext: context,
            operation: "create",
            tableName: "calendar_events",
            recordId: "evt-001",
            expectedIdentityLease: syncManager.currentIdentityLease!
        )

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1, "Should have exactly one queued action")
    }

    func testAccountDeletionPurgesDeviceRecords() throws {
        let schema = Schema(versionedSchema: HausKlarSchemaV5.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let deletionContainer = try ModelContainer(for: schema, configurations: [configuration])
        let deletionContext = ModelContext(deletionContainer)
        deletionContext.insert(OfflineAction(tableName: "tasks", recordId: "private-task"))
        try deletionContext.save()

        try SettingsViewModel.purgeLocalData(deletionContext)

        XCTAssertTrue(try deletionContext.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
    }

    func testQueuedActionHasStatusPending() {
        syncManager.queueOfflineAction(
            modelContext: context,
            operation: "update",
            tableName: "tasks",
            recordId: "task-001",
            expectedIdentityLease: syncManager.currentIdentityLease!
        )

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.first?.status, .pending, "New actions must start with status 'pending'")
    }

    func testQueuedActionPreservesOperationTableNameRecordId() {
        syncManager.queueOfflineAction(
            modelContext: context,
            operation: "delete",
            tableName: "medicine_doses",
            recordId: "dose-42",
            expectedIdentityLease: syncManager.currentIdentityLease!
        )

        let action = try! context.fetch(FetchDescriptor<OfflineAction>()).first!
        XCTAssertEqual(action.operation, .delete)
        XCTAssertEqual(action.tableName, "medicine_doses")
        XCTAssertEqual(action.recordId, "dose-42")
    }

    func testPayloadJSONSerialization() {
        let payload: [String: Any] = [
            "title": "Buy nappies",
            "priority": 3,
        ]

        syncManager.queueOfflineAction(
            modelContext: context,
            operation: "create",
            tableName: "tasks",
            recordId: "task-002",
            payload: payload,
            expectedIdentityLease: syncManager.currentIdentityLease!
        )

        let action = try! context.fetch(FetchDescriptor<OfflineAction>()).first!

        // The payload should be valid JSON containing the keys we passed in.
        let data = action.payload.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(parsed["title"] as? String, "Buy nappies")
        XCTAssertEqual(parsed["priority"] as? Int, 3)
    }

    func testUnsupportedOperationIsRejectedInsteadOfBecomingCreate() throws {
        let queued = syncManager.queueOfflineAction(
            modelContext: context,
            operation: "upsert",
            tableName: "tasks",
            recordId: "task-upsert",
            expectedIdentityLease: syncManager.currentIdentityLease!
        )

        XCTAssertFalse(queued)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
    }

    func testMultipleQueuedActionsMaintainOrder() {
        // Queue three actions in quick succession.
        for i in 1...3 {
            syncManager.queueOfflineAction(
                modelContext: context,
                operation: "create",
                tableName: "events",
                recordId: "evt-\(i)",
                expectedIdentityLease: syncManager.currentIdentityLease!
            )
        }

        let descriptor = FetchDescriptor<OfflineAction>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let actions = try! context.fetch(descriptor)
        XCTAssertEqual(actions.count, 3, "Should have three queued actions")

        // Verify ordering: createdAt of each action should be <= the next.
        for i in 0..<(actions.count - 1) {
            XCTAssertLessThanOrEqual(
                actions[i].createdAt,
                actions[i + 1].createdAt,
                "Actions should be ordered by createdAt"
            )
        }
    }

    func testStaleIdentityLeaseCannotQueueIntoReplacementAccount() async throws {
        let accountALease = try XCTUnwrap(syncManager.currentIdentityLease)

        await syncManager.suspendAndReset()
        syncManager.activate(identity: "replacement-family:replacement-user")

        let queued = syncManager.queueOfflineAction(
            modelContext: context,
            operation: "create",
            tableName: "tasks",
            recordId: "account-a-task",
            payload: ["title": "Private work from account A"],
            expectedIdentityLease: accountALease
        )

        XCTAssertFalse(queued)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
    }

    func testQueuePreparationRetainsOldPendingAndFailedWork() throws {
        let old = Date().addingTimeInterval(-72 * 60 * 60)
        context.insert(OfflineAction(
            tableName: "tasks",
            recordId: "old-pending",
            createdAt: old,
            status: .pending
        ))
        context.insert(OfflineAction(
            tableName: "tasks",
            recordId: "old-failed",
            createdAt: old,
            status: .failed,
            retryCount: 2
        ))
        context.insert(OfflineAction(
            tableName: "tasks",
            recordId: "completed",
            createdAt: old,
            status: .synced
        ))
        try context.save()

        syncManager.prepareQueueForSync(modelContext: context)

        let actions = try context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(Set(actions.map(\.recordId)), ["old-pending", "old-failed"])
    }

    func testQueuePreparationRecoversCrashInterruptedSyncingAction() throws {
        let action = OfflineAction(
            tableName: "calendar_events",
            recordId: "interrupted",
            status: .syncing,
            retryCount: 1
        )
        context.insert(action)
        try context.save()

        syncManager.prepareQueueForSync(modelContext: context)

        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(action.retryCount, 1, "A process interruption is not a server failure")
    }

    func testFailedDurableStageRollsBackBothLocalMutationAndReplayIntent() throws {
        enum InjectedFailure: Error { case save }
        let manager = SyncManager(saveQueueContext: { _ in
            throw InjectedFailure.save
        })
        manager.activate(identity: "test-family:test-user")
        let lease = try XCTUnwrap(manager.currentIdentityLease)

        XCTAssertThrowsError(
            try manager.stageDurableAction(
                modelContext: context,
                actionID: "dose-atomic",
                operation: .create,
                tableName: "medicine_doses",
                recordId: "dose-atomic",
                payload: [
                    "medicine_type_id": "medicine-1",
                    "child_id": "child-1",
                    "given_at": "2026-08-10T12:00:00Z",
                ],
                expectedIdentityLease: lease
            ) {
                context.insert(
                    MedicineDose(
                        id: "dose-atomic",
                        medicineTypeId: "medicine-1",
                        childId: "child-1",
                        givenAt: Date(timeIntervalSince1970: 1_754_827_200)
                    )
                )
            }
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<MedicineDose>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
    }

    func testLiveDirectAttemptCannotRaceSyncAndRelaunchReleasesItForReplay() throws {
        let foregroundManager = SyncManager()
        foregroundManager.activate(identity: "test-family:test-user")
        let foregroundLease = try XCTUnwrap(foregroundManager.currentIdentityLease)
        let givenAt = Date(timeIntervalSince1970: 1_754_827_200)
        try foregroundManager.stageDurableAction(
            modelContext: context,
            actionID: "dose-before-transport",
            operation: .create,
            tableName: "medicine_doses",
            recordId: "dose-before-transport",
            payload: [
                "medicine_type_id": "medicine-1",
                "child_id": "child-1",
                "given_at": ISODateParser.stringNoFractional(from: givenAt),
            ],
            expectedIdentityLease: foregroundLease
        ) {
            context.insert(
                MedicineDose(
                    id: "dose-before-transport",
                    medicineTypeId: "medicine-1",
                    childId: "child-1",
                    givenAt: givenAt
                )
            )
        }

        XCTAssertTrue(foregroundManager.prepareQueueForSync(modelContext: context))
        var action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.status, .directAttempt, "Live foreground transport retains its claim")

        let relaunchedManager = SyncManager()
        relaunchedManager.activate(identity: "test-family:test-user")
        XCTAssertTrue(relaunchedManager.prepareQueueForSync(modelContext: context))

        action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(action.retryCount, 0, "A process interruption is not a failed attempt")
        XCTAssertEqual(action.id, "dose-before-transport")
        XCTAssertEqual(action.recordId, "dose-before-transport")
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<MedicineDose>()).map(\.id),
            ["dose-before-transport"]
        )
    }

    func testDurableMutationCancellationRetainsMirrorAndPendingReplay() async throws {
        let manager = SyncManager()
        manager.activate(identity: "test-family:test-user")
        let lease = try XCTUnwrap(manager.currentIdentityLease)

        let outcome: SyncManager.DurableMutationOutcome<String> = await manager.performDurableMutation(
            modelContext: context,
            actionID: "cancelled-create",
            operation: .create,
            tableName: "tasks",
            recordId: "cancelled-task",
            payload: ["title": "Durable first"],
            expectedIdentityLease: lease
        ) {
            context.insert(FamilyTask(id: "cancelled-task", title: "Durable first"))
        } transport: {
            throw CancellationError()
        } applyAcknowledgedResult: { _ in }

        guard case .transportFailed(status: .pending, error: _) = outcome else {
            return XCTFail("Cancellation should release the exact operation to pending")
        }
        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.id, "cancelled-create")
        XCTAssertEqual(action.retryCount, 0)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FamilyTask>()).map(\.title),
            ["Durable first"]
        )
    }

    func testDurableMutationStageFailureRollsBackAndNeverStartsTransport() async throws {
        enum InjectedFailure: Error { case stageSave }
        let manager = SyncManager(saveQueueContext: { _ in
            throw InjectedFailure.stageSave
        })
        manager.activate(identity: "test-family:test-user")
        let lease = try XCTUnwrap(manager.currentIdentityLease)
        var transportCount = 0

        let outcome: SyncManager.DurableMutationOutcome<Void> = await manager.performDurableMutation(
            modelContext: context,
            actionID: "failed-stage",
            operation: .create,
            tableName: "tasks",
            recordId: "failed-stage-task",
            payload: ["title": "Never sent"],
            expectedIdentityLease: lease
        ) {
            context.insert(FamilyTask(id: "failed-stage-task", title: "Never sent"))
        } transport: {
            transportCount += 1
        } applyAcknowledgedResult: { _ in }

        guard case .stagingFailed = outcome else {
            return XCTFail("A failed first save must stop before transport")
        }
        XCTAssertEqual(transportCount, 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FamilyTask>()).isEmpty)
    }

    func testDurableMutationAcknowledgementSaveFailureRetainsOptimisticMirror() async throws {
        enum InjectedFailure: Error { case acknowledgementSave }
        var saveCount = 0
        let manager = SyncManager(saveQueueContext: { modelContext in
            saveCount += 1
            if saveCount == 2 { throw InjectedFailure.acknowledgementSave }
            try modelContext.save()
        })
        manager.activate(identity: "test-family:test-user")
        let lease = try XCTUnwrap(manager.currentIdentityLease)

        let outcome: SyncManager.DurableMutationOutcome<String> = await manager.performDurableMutation(
            modelContext: context,
            actionID: "ack-save-operation",
            operation: .create,
            tableName: "tasks",
            recordId: "ack-save-task",
            payload: ["title": "Optimistic"],
            expectedIdentityLease: lease
        ) {
            context.insert(FamilyTask(id: "ack-save-task", title: "Optimistic"))
        } transport: {
            "Server"
        } applyAcknowledgedResult: { title in
            let id = "ack-save-task"
            let task = try XCTUnwrap(context.fetch(FetchDescriptor<FamilyTask>(
                predicate: #Predicate { $0.id == id }
            )).first)
            task.title = title
        }

        guard case .acknowledgementPending = outcome else {
            return XCTFail("A failed acknowledgement save must retain replay")
        }
        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        let task = try XCTUnwrap(try context.fetch(FetchDescriptor<FamilyTask>()).first)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(action.retryCount, 0)
        XCTAssertEqual(task.title, "Optimistic", "Rollback must restore the durable optimistic mirror")
    }

    func testDurableMutationPermanentFailureLeavesInspectableDeadLetter() async throws {
        let manager = SyncManager()
        manager.activate(identity: "test-family:test-user")
        let lease = try XCTUnwrap(manager.currentIdentityLease)

        let outcome: SyncManager.DurableMutationOutcome<Void> = await manager.performDurableMutation(
            modelContext: context,
            actionID: "rejected-create",
            operation: .create,
            tableName: "tasks",
            recordId: "rejected-task",
            payload: ["title": "Rejected"],
            expectedIdentityLease: lease
        ) {
            context.insert(FamilyTask(id: "rejected-task", title: "Rejected"))
        } transport: {
            throw APIError.serverError(statusCode: 400, message: "invalid")
        } applyAcknowledgedResult: { _ in }

        guard case .transportFailed(status: .permanent, error: _) = outcome else {
            return XCTFail("A semantic 4xx should become an inspectable dead letter")
        }
        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.status, .permanent)
        XCTAssertEqual(action.lastStatusCode, 400)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FamilyTask>()).count, 1)
    }

    func testDuplicateStableOperationCannotMutateOrStartSecondTransport() async throws {
        let manager = SyncManager()
        manager.activate(identity: "test-family:test-user")
        let lease = try XCTUnwrap(manager.currentIdentityLease)
        try manager.stageDurableAction(
            modelContext: context,
            actionID: "stable-duplicate",
            operation: .create,
            tableName: "tasks",
            recordId: "duplicate-task",
            payload: ["title": "First"],
            expectedIdentityLease: lease
        ) {
            context.insert(FamilyTask(id: "duplicate-task", title: "First"))
        }

        XCTAssertThrowsError(try manager.stageDurableAction(
            modelContext: context,
            actionID: "stable-duplicate",
            operation: .update,
            tableName: "tasks",
            recordId: "duplicate-task",
            payload: ["title": "Second"],
            expectedIdentityLease: lease
        ) {
            let task = try XCTUnwrap(context.fetch(FetchDescriptor<FamilyTask>()).first)
            task.title = "Second"
        })
        XCTAssertEqual(try context.fetch(FetchDescriptor<OfflineAction>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FamilyTask>()).first?.title, "First")
    }

    func testAccountSwitchDuringAcknowledgementRetainsRecoverableOperation() async throws {
        let manager = SyncManager()
        manager.activate(identity: "family-a:user-a")
        let lease = try XCTUnwrap(manager.currentIdentityLease)

        let outcome: SyncManager.DurableMutationOutcome<String> = await manager.performDurableMutation(
            modelContext: context,
            actionID: "account-a-operation",
            operation: .create,
            tableName: "tasks",
            recordId: "account-a-task",
            payload: ["title": "Account A"],
            expectedIdentityLease: lease
        ) {
            context.insert(FamilyTask(id: "account-a-task", title: "Account A"))
        } transport: {
            manager.activate(identity: "family-b:user-b")
            return "Account A server receipt"
        } applyAcknowledgedResult: { title in
            let task = try XCTUnwrap(context.fetch(FetchDescriptor<FamilyTask>()).first)
            task.title = title
        }

        guard case .acknowledgementPending = outcome else {
            return XCTFail("A stale account lease must never acknowledge into the replacement account")
        }
        var action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.status, .directAttempt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FamilyTask>()).first?.title, "Account A")

        let relaunched = SyncManager()
        relaunched.activate(identity: "family-a:user-a")
        XCTAssertTrue(relaunched.prepareQueueForSync(modelContext: context))
        action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(action.status, .pending)
    }

    func testTwoWritesForOneRecordReplayInStrictCreationOrder() async throws {
        let lock = NSLock()
        var pushedOperationIDs: [String] = []
        let harness = makeStubbedSyncManager { [self] request in
            if request.url?.path.hasSuffix("/sync/push") == true {
                let body = try syncRequestBodyData(request)
                let json = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                let items = try XCTUnwrap(json["items"] as? [[String: Any]])
                let operationID = try XCTUnwrap(items.first?["operation_id"] as? String)
                lock.withLock { pushedOperationIDs.append(operationID) }
                return try jsonResponse(
                    for: request,
                    body: "{\"results\":[{\"operation_id\":\"\(operationID)\",\"record_id\":\"ordered-task\",\"status\":\"accepted\"}]}"
                )
            }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let lease = try XCTUnwrap(harness.manager.currentIdentityLease)
        let first: SyncManager.DurableMutationOutcome<Void> = await harness.manager.performDurableMutation(
            modelContext: context,
            actionID: "ordered-create",
            operation: .create,
            tableName: "tasks",
            recordId: "ordered-task",
            payload: ["title": "First"],
            expectedIdentityLease: lease
        ) {
            context.insert(FamilyTask(id: "ordered-task", title: "First"))
        } transport: {
            throw URLError(.notConnectedToInternet)
        } applyAcknowledgedResult: { _ in }
        guard case .transportFailed(status: .pending, error: _) = first else {
            return XCTFail("The first write should be pending")
        }

        var secondTransportCount = 0
        let second: SyncManager.DurableMutationOutcome<Void> = await harness.manager.performDurableMutation(
            modelContext: context,
            actionID: "ordered-update",
            operation: .update,
            tableName: "tasks",
            recordId: "ordered-task",
            payload: ["title": "Second"],
            expectedIdentityLease: lease
        ) {
            let task = try XCTUnwrap(context.fetch(FetchDescriptor<FamilyTask>()).first)
            task.title = "Second"
        } transport: {
            secondTransportCount += 1
        } applyAcknowledgedResult: { _ in }
        guard case .queued = second else {
            return XCTFail("A later write must defer behind the pending create")
        }
        XCTAssertEqual(secondTransportCount, 0)
        let staged = try context.fetch(FetchDescriptor<OfflineAction>())
        staged.first(where: { $0.id == "ordered-create" })?.createdAt = Date(
            timeIntervalSince1970: 1_000
        )
        staged.first(where: { $0.id == "ordered-update" })?.createdAt = Date(
            timeIntervalSince1970: 1_001
        )
        try context.save()

        await harness.manager.syncNow(modelContext: context)
        await harness.manager.syncNow(modelContext: context)

        XCTAssertEqual(lock.withLock { pushedOperationIDs }, ["ordered-create", "ordered-update"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<FamilyTask>()).first?.title, "Second")
    }

    func testSuspendingIdentityClearsSyncCursor() async {
        let key = "sync.lastSyncTimestamp"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set("2026-07-17T12:00:00Z", forKey: key)
        let manager = SyncManager()
        manager.activate(identity: "family:a")

        await manager.suspendAndReset()

        XCTAssertNil(manager.lastSyncTimestamp)
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
        XCTAssertFalse(manager.isIdentityActive)
    }

    func testSyncPushResponseDecodesAndSurfacesMedicineSafetyWarnings() throws {
        let data = Data(
            #"""
            {
              "results": [
                {
                  "record_id": "dose-1",
                  "status": "accepted",
                  "detail": null,
                  "warnings": [
                    {
                      "type": "too_soon",
                      "message": "Only 1.0h since last dose.",
                      "next_safe_at": "2026-07-11T12:00:00Z"
                    }
                  ]
                },
                {
                  "record_id": "dose-2",
                  "status": "error",
                  "warnings": [
                    {
                      "type": "max_reached",
                      "message": "Rejected warning must not be surfaced.",
                      "next_safe_at": null
                    }
                  ]
                }
              ]
            }
            """#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(SyncManager.SyncPushResponse.self, from: data)

        XCTAssertEqual(response.results.count, 2)
        XCTAssertEqual(response.results[0].warnings.first?.type, "too_soon")
        XCTAssertEqual(response.results[0].warnings.first?.nextSafeAt, "2026-07-11T12:00:00Z")
        syncManager.surfaceMedicineSafetyWarnings(from: response)
        XCTAssertTrue(syncManager.showMedicineSafetyWarning)
        XCTAssertEqual(syncManager.medicineSafetyWarnings.map(\.message), ["Only 1.0h since last dose."])

        syncManager.acknowledgeMedicineSafetyWarnings()
        XCTAssertFalse(syncManager.showMedicineSafetyWarning)
        XCTAssertTrue(syncManager.medicineSafetyWarnings.isEmpty)
    }

    func testSyncPushResponseDefaultsMissingWarningsToEmpty() throws {
        let data = Data(#"{"results":[{"record_id":"task-1","status":"accepted"}]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(SyncManager.SyncPushResponse.self, from: data)

        XCTAssertTrue(response.results[0].warnings.isEmpty)
        XCTAssertNil(response.results[0].detail)
    }

    func testPullBatchUpdatesExistingAndCoalescesRepeatedRecords() throws {
        let schema = Schema([FamilyTask.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let pullContainer = try ModelContainer(for: schema, configurations: [configuration])
        let pullContext = ModelContext(pullContainer)
        pullContext.insert(FamilyTask(id: "existing", title: "Old title"))
        try pullContext.save()

        let timestamp = "2026-07-10T08:00:00Z"
        let records = [
            SyncManager.SyncPullRecord(
                tableName: "tasks",
                recordId: "existing",
                operation: "update",
                data: [
                    "title": .string("Updated title"),
                    "updated_at": .string(timestamp),
                ]
            ),
            SyncManager.SyncPullRecord(
                tableName: "tasks",
                recordId: "new-task",
                operation: "update",
                data: [
                    "title": .string("First version"),
                    "updated_at": .string(timestamp),
                ]
            ),
            SyncManager.SyncPullRecord(
                tableName: "tasks",
                recordId: "new-task",
                operation: "update",
                data: [
                    "title": .string("Final version"),
                    "updated_at": .string(timestamp),
                ]
            ),
        ]

        syncManager.applyPullRecords(records, modelContext: pullContext)
        try pullContext.save()

        let tasks = try pullContext.fetch(FetchDescriptor<FamilyTask>())
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.first(where: { $0.id == "existing" })?.title, "Updated title")
        XCTAssertEqual(tasks.first(where: { $0.id == "new-task" })?.title, "Final version")
    }

    func testMalformedMedicinePullDoesNotCreateDoseOrAdvanceCursor() async throws {
        let timestamp = "2026-08-10T12:00:00Z"
        let harness = makeStubbedSyncManager { [self] request in
            try jsonResponse(
                for: request,
                body: #"{"records":[{"table_name":"medicine_doses","record_id":"bad-dose","operation":"update","updated_at":"\#(timestamp)","data":{"id":"bad-dose","medicine_type_id":"type-1","child_id":"child-1","given_at":"not-a-date","given_by":"Alex","created_at":"\#(timestamp)","updated_at":"\#(timestamp)"}}],"server_timestamp":"\#(timestamp)","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        XCTAssertNil(harness.manager.lastSyncTimestamp)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MedicineDose>()).isEmpty)
        XCTAssertNil(harness.defaults.string(forKey: "sync.lastSyncTimestamp"))
    }

    func testSimultaneousSyncTriggersJoinOnePushPullCycle() async throws {
        let lock = NSLock()
        var pullRequestCount = 0
        let harness = makeStubbedSyncManager { [self] request in
            if request.url?.path.hasSuffix("/sync/pull") == true {
                lock.withLock { pullRequestCount += 1 }
                Thread.sleep(forTimeInterval: 0.15)
            }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        let first = Task { @MainActor in
            await harness.manager.syncNow(modelContext: context)
        }
        await Task.yield()
        let second = Task { @MainActor in
            await harness.manager.syncNow(modelContext: context)
        }
        await first.value
        await second.value

        XCTAssertEqual(lock.withLock { pullRequestCount }, 1)
        XCTAssertEqual(harness.manager.lastSyncTimestamp, "2026-08-10T12:00:00Z")
        XCTAssertFalse(harness.manager.isSyncing)
    }

    func testAmbiguousLegacyRecordIDAcknowledgementDoesNotDeleteActions() async throws {
        context.insert(OfflineAction(tableName: "tasks", recordId: "shared-id"))
        context.insert(OfflineAction(tableName: "calendar_events", recordId: "shared-id"))
        try context.save()
        let harness = makeStubbedSyncManager { [self] request in
            if request.httpMethod == "POST" {
                return try jsonResponse(
                    for: request,
                    body: #"{"results":[{"record_id":"shared-id","status":"accepted"}]}"#
                )
            }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        let actions = try context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.allSatisfy { $0.status == .permanent })
        XCTAssertTrue(actions.allSatisfy { $0.retryCount == 1 })
    }

    func testUnambiguousLegacyRecordIDAcknowledgementRemainsCompatible() async throws {
        context.insert(OfflineAction(tableName: "tasks", recordId: "legacy-id"))
        try context.save()
        let harness = makeStubbedSyncManager { [self] request in
            if request.httpMethod == "POST" {
                return try jsonResponse(
                    for: request,
                    body: #"{"results":[{"record_id":"legacy-id","status":"accepted"}]}"#
                )
            }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
    }

    func testDuplicateOperationIDAcknowledgementsBecomeProtocolDeadLetter() async throws {
        let action = OfflineAction(
            id: "operation-duplicate",
            tableName: "tasks",
            recordId: "task-duplicate"
        )
        context.insert(action)
        try context.save()
        let harness = makeStubbedSyncManager { [self] request in
            if request.httpMethod == "POST" {
                return try jsonResponse(
                    for: request,
                    body: #"{"results":[{"operation_id":"operation-duplicate","record_id":"task-duplicate","status":"accepted"},{"operation_id":"operation-duplicate","record_id":"task-duplicate","status":"accepted"}]}"#
                )
            }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        let retained = try XCTUnwrap(
            try context.fetch(FetchDescriptor<OfflineAction>()).first
        )
        XCTAssertEqual(retained.status, .permanent)
        XCTAssertEqual(retained.retryCount, 1)
        XCTAssertTrue(retained.lastError?.contains("duplicate acknowledgements") == true)
    }

    func testSyncPullIsExplicitlyNetworkOnlyAndNeverUsesFileCache() async throws {
        let harness = makeStubbedSyncManager { request in
            if request.url?.path.hasSuffix("/sync/pull") == true {
                throw URLError(.notConnectedToInternet)
            }
            throw URLError(.notConnectedToInternet)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        var components = URLComponents(string: harness.client.baseURL + "/sync/pull")!
        components.queryItems = [
            URLQueryItem(name: "since", value: "1970-01-01T00:00:00Z"),
            URLQueryItem(name: "limit", value: "500"),
        ]
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try harness.client.responseCacheKey(for: request)
        await FileCache.shared.set(
            key,
            data: Data(
                #"{"records":[],"server_timestamp":"cached-value","next_cursor":null,"has_more":false}"#.utf8
            )
        )
        await harness.manager.syncNow(modelContext: context)

        XCTAssertNil(harness.manager.lastSyncTimestamp)
        XCTAssertNil(harness.defaults.string(forKey: "sync.lastSyncTimestamp"))
        await FileCache.shared.remove { $0 == key }
    }

    func testFailedDurableClaimNeverStartsPushTransport() async throws {
        enum InjectedFailure: Error { case claimSave }
        context.insert(OfflineAction(id: "claim", tableName: "tasks", recordId: "task"))
        try context.save()
        let lock = NSLock()
        var saveCount = 0
        var postCount = 0
        let harness = makeStubbedSyncManager(
            saveQueueContext: { modelContext in
                let call = lock.withLock { () -> Int in
                    saveCount += 1
                    return saveCount
                }
                if call == 3 { throw InjectedFailure.claimSave }
                try modelContext.save()
            },
            handler: { [self] request in
                if request.httpMethod == "POST" { lock.withLock { postCount += 1 } }
                return try jsonResponse(
                    for: request,
                    body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
                )
            }
        )
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        XCTAssertEqual(lock.withLock { postCount }, 0)
        let retained = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(retained.status, .pending)
        XCTAssertEqual(retained.retryCount, 0)
    }

    func testFailedAcknowledgementSaveReleasesStableOperationForReplay() async throws {
        enum InjectedFailure: Error { case resultSave }
        context.insert(OfflineAction(
            id: "stable-operation",
            tableName: "tasks",
            recordId: "task"
        ))
        try context.save()
        let lock = NSLock()
        var saveCount = 0
        let harness = makeStubbedSyncManager(
            saveQueueContext: { modelContext in
                let call = lock.withLock { () -> Int in
                    saveCount += 1
                    return saveCount
                }
                if call == 4 { throw InjectedFailure.resultSave }
                try modelContext.save()
            },
            handler: { [self] request in
                if request.httpMethod == "POST" {
                    return try jsonResponse(
                        for: request,
                        body: #"{"results":[{"operation_id":"stable-operation","record_id":"task","status":"accepted"}]}"#
                    )
                }
                return try jsonResponse(
                    for: request,
                    body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
                )
            }
        )
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        let retained = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(retained.id, "stable-operation")
        XCTAssertEqual(retained.status, .pending)
        XCTAssertEqual(retained.retryCount, 0)
        XCTAssertTrue(retained.lastError?.contains("replay is pending") == true)
    }

    func testCancellationRestoresClaimWithoutIncrementingRetry() async throws {
        context.insert(OfflineAction(id: "cancelled", tableName: "tasks", recordId: "task"))
        try context.save()
        let harness = makeStubbedSyncManager { request in
            if request.httpMethod == "POST" { throw URLError(.cancelled) }
            throw URLError(.cancelled)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        let retained = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(retained.status, .pending)
        XCTAssertEqual(retained.retryCount, 0)
    }

    func testTransientFailureUsesDeterministicBackoffAndPermanent4xxDeadLetters() async throws {
        let instant = Date(timeIntervalSince1970: 20_000)
        context.insert(OfflineAction(id: "retry", tableName: "tasks", recordId: "retry"))
        try context.save()
        let transient = makeStubbedSyncManager(
            now: { instant },
            handler: { [self] request in
                if request.httpMethod == "POST" {
                    return try jsonResponse(for: request, statusCode: 503, body: #"{"detail":"down"}"#)
                }
                throw URLError(.notConnectedToInternet)
            }
        )
        defer {
            transient.client.clearSession()
            transient.defaults.removePersistentDomain(forName: transient.suiteName)
        }

        await transient.manager.syncNow(modelContext: context)

        var retained = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(retained.status, .retryable)
        XCTAssertEqual(retained.retryCount, 1)
        XCTAssertEqual(retained.nextAttemptAt, instant.addingTimeInterval(5))

        context.delete(retained)
        context.insert(OfflineAction(id: "bad-request", tableName: "tasks", recordId: "bad"))
        try context.save()
        let permanent = makeStubbedSyncManager { [self] request in
            if request.httpMethod == "POST" {
                return try jsonResponse(for: request, statusCode: 400, body: #"{"detail":"invalid"}"#)
            }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            permanent.client.clearSession()
            permanent.defaults.removePersistentDomain(forName: permanent.suiteName)
        }

        await permanent.manager.syncNow(modelContext: context)

        retained = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(retained.status, .permanent)
        XCTAssertEqual(retained.lastStatusCode, 400)
    }

    func testFailedDiscardRollsBackAndRetainsDurableAction() throws {
        enum InjectedFailure: Error { case discardSave }
        let action = OfflineAction(id: "retain-me", tableName: "tasks", recordId: "task")
        context.insert(action)
        try context.save()
        let manager = SyncManager(saveQueueContext: { _ in
            throw InjectedFailure.discardSave
        })
        manager.activate(identity: "test-family:test-user")

        let discarded = manager.discardOfflineAction(id: action.id, modelContext: context)

        XCTAssertFalse(discarded)
        let retained = try context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(retained.map(\.id), ["retain-me"])
    }

    func testMalformedQueuedPayloadIsQuarantinedWithoutTransport() async throws {
        let action = OfflineAction(
            id: "malformed-payload",
            tableName: "tasks",
            recordId: "task",
            payload: "{not-json"
        )
        context.insert(action)
        try context.save()
        let lock = NSLock()
        var postCount = 0
        let harness = makeStubbedSyncManager { [self] request in
            if request.httpMethod == "POST" {
                lock.withLock { postCount += 1 }
            }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":null,"has_more":false}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        XCTAssertEqual(lock.withLock { postCount }, 0)
        let retained = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        XCTAssertEqual(retained.status, .permanent)
        XCTAssertTrue(retained.lastError?.contains("malformed") == true)
    }

    func testRepeatedPullCursorFailsClosedWithoutAdvancingTimestamp() async throws {
        let lock = NSLock()
        var pullCount = 0
        let harness = makeStubbedSyncManager { [self] request in
            lock.withLock { pullCount += 1 }
            return try jsonResponse(
                for: request,
                body: #"{"records":[],"server_timestamp":"2026-08-10T12:00:00Z","next_cursor":"loop","has_more":true}"#
            )
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }

        await harness.manager.syncNow(modelContext: context)

        XCTAssertEqual(lock.withLock { pullCount }, 2)
        XCTAssertNil(harness.manager.lastSyncTimestamp)
        XCTAssertNil(harness.defaults.string(forKey: "sync.lastSyncTimestamp"))
    }

    // MARK: - Offline fallback wiring (ViewModels)

    func testNapStartStagesMirrorBeforeTransportAndRetainsItOnNetworkFailure() async throws {
        let lock = NSLock()
        var requestedPaths: [String] = []
        let harness = makeStubbedSyncManager { request in
            lock.withLock { requestedPaths.append(request.url?.path ?? "") }
            throw URLError(.notConnectedToInternet)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let vm = NapsViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        vm.bindModelContext(context)
        let child = ChildDTO(
            id: "child-nap",
            name: "Child One",
            dateOfBirth: "2020-01-01"
        )
        vm.children = [child]

        await vm.quickStartNap(for: child)

        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        let nap = try XCTUnwrap(try context.fetch(FetchDescriptor<Nap>()).first)
        XCTAssertEqual(action.id, nap.id)
        XCTAssertEqual(action.recordId, nap.id)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(action.retryCount, 0)
        XCTAssertEqual(vm.activeNaps.map(\.id), [nap.id])
        XCTAssertEqual(lock.withLock { requestedPaths }, ["/api/naps/start"])

        let relaunched = NapsViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        relaunched.bindModelContext(context)
        XCTAssertEqual(relaunched.activeNaps.map(\.id), [nap.id])
    }

    func testHolidayDateExpansionIsInclusiveAcrossLeapDayAndTotalForReverseRange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2028, month: 2, day: 28, hour: 12)
        ))
        let end = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2028, month: 3, day: 1, hour: 12)
        ))

        let expanded = CalendarViewModel.holidayDates(
            from: start,
            through: end,
            calendar: calendar
        )

        XCTAssertEqual(expanded.count, 3)
        XCTAssertEqual(
            expanded.map { calendar.component(.day, from: $0) },
            [28, 29, 1]
        )
        XCTAssertEqual(
            CalendarViewModel.holidayDates(
                from: end,
                through: start,
                calendar: calendar
            ),
            [end]
        )
    }

    func testSelectingTaskCategoryUpdatesTheUnifiedListQuery() {
        let vm = TasksViewModel()

        vm.selectCategory("bins")
        XCTAssertEqual(vm.selectedCategory, "bins")
        XCTAssertEqual(vm.querySignature, TaskQuerySignature(category: "bins"))

        vm.selectCategory(nil)
        XCTAssertEqual(vm.querySignature, TaskQuerySignature(category: nil))
    }

    func testTaskGroupingKeepsTodaySoonWaitingAndCompletedDistinct() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-14T12:00:00Z"))

        XCTAssertEqual(
            TaskGrouping.section(
                for: taskDTO(id: "today", title: "Today", dueDate: "2026-07-14"),
                now: now,
                calendar: calendar
            ),
            .todayAndOverdue
        )
        XCTAssertEqual(
            TaskGrouping.section(for: taskDTO(id: "soon", title: "Soon"), now: now, calendar: calendar),
            .soon
        )
        XCTAssertEqual(
            TaskGrouping.section(
                for: taskDTO(
                    id: "waiting",
                    title: "Waiting",
                    dueDate: "2026-07-14",
                    actionableFrom: "2026-07-15T09:00:00Z"
                ),
                now: now,
                calendar: calendar
            ),
            .waiting,
            "Hide-until takes precedence over an approaching due date"
        )
        XCTAssertEqual(
            TaskGrouping.section(
                for: taskDTO(
                    id: "done",
                    title: "Done",
                    completedAt: "2026-07-14T11:00:00Z",
                    actionableFrom: "2026-07-15T09:00:00Z"
                ),
                now: now,
                calendar: calendar
            ),
            .completed
        )
    }

    func testTasksLoadIgnoresDelayedOlderFilterResponse() async {
        let stale = taskDTO(id: "stale", title: "Stale task")
        let latest = taskDTO(id: "latest", title: "Latest bins", category: "bins")
        let vm = TasksViewModel(taskListLoader: { queryItems in
            let isBins = queryItems.contains { item in
                item.name == "category" && item.value == "bins"
            }
            if isBins {
                try await Task.sleep(nanoseconds: 10_000_000)
                return [latest]
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            return [stale]
        })

        let firstLoad = Task { await vm.loadTasks() }
        while !vm.isLoading {
            await Task.yield()
        }
        vm.selectCategory("bins")
        let secondLoad = Task { await vm.loadTasks() }

        await secondLoad.value
        await firstLoad.value

        XCTAssertEqual(vm.tasks.map(\.id), ["latest"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testManagedBinsAreSharedInMineAndCannotBeDeleted() async {
        let katAssignment = TaskAssigneeDTO(
            id: "kat-bin-assignment",
            assigneeId: "kat",
            assigneeType: "user",
            assigneeName: "Morgan",
            completedAt: nil,
            completedBy: nil
        )
        let managed = taskDTO(
            id: "managed-bins",
            title: "Bins",
            category: "bins",
            createdBy: "bin-scraper",
            assignedTo: "kat",
            assignees: [katAssignment]
        )
        let ordinary = taskDTO(
            id: "kat-task",
            title: "Morgan's task",
            createdBy: "kat",
            assignedTo: "kat",
            assignees: [katAssignment]
        )
        let vm = TasksViewModel()
        vm.tasks = [managed]

        XCTAssertTrue(vm.taskIsVisibleInMine(managed, currentUserId: "dom"))
        XCTAssertFalse(vm.taskIsVisibleInMine(ordinary, currentUserId: "dom"))
        XCTAssertFalse(vm.canDeleteTask(managed))
        XCTAssertFalse(vm.canEditTask(managed))

        await vm.deleteTask(managed.id)
        XCTAssertEqual(vm.tasks.map(\.id), [managed.id])
        XCTAssertEqual(vm.errorMessage, "This task is managed from the council schedule.")
    }

    func testFinanceManagedTaskCannotEditDeleteOrQueueCompletionOffline() async {
        let managedSource = ManagedSourceDTO(
            kind: "finance_commitment",
            sourceId: "commitment-1",
            deepLink: "/?view=finance&section=plan&commitment=commitment-1",
            label: "Household Finance"
        )
        let managed = taskDTO(
            id: "finance-task-occurrence",
            title: "Pay school fees",
            assignedTo: "dom",
            readOnly: true,
            managedSource: managedSource
        )
        let vm = TasksViewModel(
            taskCompleter: { _ in
                throw APIError.networkError(URLError(.notConnectedToInternet))
            },
            syncManager: syncManager
        )
        vm.bindModelContext(context)
        vm.tasks = [managed]

        XCTAssertFalse(vm.canEditTask(managed))
        XCTAssertFalse(vm.canDeleteTask(managed))
        await vm.completeTask(managed.id)

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(vm.tasks.first?.completedAt)
        XCTAssertEqual(
            vm.errorMessage,
            "Reconnect to complete this Finance-managed task."
        )
    }

    func testLibraryManagedTaskCannotEditDeleteOrQueueCompletionOffline() async {
        let managedSource = ManagedSourceDTO(
            kind: "library_loan",
            sourceId: "loan-1",
            deepLink: "/?view=lists&section=renewals&library=loan-1",
            label: "Library book"
        )
        let managed = taskDTO(
            id: "library-task-loan-1",
            title: "Renew or return The Wild Robot",
            readOnly: true,
            managedSource: managedSource
        )
        let vm = TasksViewModel(
            taskCompleter: { _ in
                throw APIError.networkError(URLError(.notConnectedToInternet))
            },
            syncManager: syncManager
        )
        vm.bindModelContext(context)
        vm.tasks = [managed]

        XCTAssertTrue(managed.isManaged)
        XCTAssertTrue(managed.isLibraryManaged)
        XCTAssertFalse(managed.isFinanceManaged)
        XCTAssertEqual(managed.managedCategoryLabel, "Library")
        XCTAssertFalse(vm.canEditTask(managed))
        XCTAssertFalse(vm.canDeleteTask(managed))
        await vm.completeTask(managed.id)

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(vm.tasks.first?.completedAt)
        XCTAssertEqual(vm.errorMessage, "Reconnect to complete this library task.")
    }

    func testDateOnlyTaskBecomesOverdueAfterItsCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let dueDayNoon = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 14, hour: 12)
        )!
        let followingDay = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 15, hour: 0)
        )!

        XCTAssertFalse(
            TaskDatePresentation.isOverdue(
                "2026-07-14",
                now: dueDayNoon,
                calendar: calendar
            )
        )
        XCTAssertTrue(
            TaskDatePresentation.isOverdue(
                "2026-07-14",
                now: followingDay,
                calendar: calendar
            )
        )
    }

    func testTasksCreateQueuesOfflineActionOnNetworkFailure() async {
        let vm = TasksViewModel(
            taskCreator: { _ in
                throw APIError.networkError(URLError(.notConnectedToInternet))
            },
            syncManager: syncManager
        )
        vm.bindModelContext(context)
        vm.formTitle = "Offline task"
        vm.formCategory = "household"
        vm.formPriority = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        vm.formDueDate = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 4, hour: 18)
        )!
        vm.setFormRecurrence(.monthly)
        let document = sourceDocument()
        vm.formSourceDocument = document

        await vm.createTask()

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .create)
        XCTAssertEqual(actions[0].tableName, "tasks")
        XCTAssertFalse(vm.tasks.isEmpty, "Task should be optimistically added while offline")
        XCTAssertEqual(actions[0].recordId, vm.tasks[0].id)
        let payload = try! JSONSerialization.jsonObject(
            with: Data(actions[0].payload.utf8)
        ) as! [String: Any]
        XCTAssertEqual(payload["source_document_id"] as? String, document.id)
        XCTAssertEqual(payload["recurrence_rule"] as? String, "FREQ=MONTHLY")
        XCTAssertEqual(vm.tasks[0].recurrenceRule, "FREQ=MONTHLY")
        XCTAssertEqual(vm.tasks[0].sourceDocumentId, document.id)
        XCTAssertEqual(vm.tasks[0].sourceDocument, document)

        let relaunched = TasksViewModel(syncManager: syncManager)
        relaunched.bindModelContext(context)
        XCTAssertEqual(relaunched.tasks.map(\.title), ["Offline task"])
    }

    func testTaskCreateSendsMonthlyRecurrenceWithItsDueDate() async {
        var capturedBody: TaskCreateRequestBody?
        let created = taskDTO(
            id: "monthly-task",
            title: "Pay Little Gym",
            dueDate: "2026-09-04T18:00:00+01:00",
            recurrenceRule: "FREQ=MONTHLY"
        )
        let vm = TasksViewModel(
            taskListLoader: { _ in [] },
            taskCreator: { body in
                capturedBody = body
                return created
            }
        )
        vm.bindModelContext(context)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        vm.formTitle = "Pay Little Gym"
        vm.formDueDate = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 4, hour: 18)
        )!
        vm.setFormRecurrence(.monthly)

        await vm.createTask()

        XCTAssertTrue(capturedBody?.dueDate?.contains("2026-09-04") == true)
        XCTAssertEqual(capturedBody?.recurrenceRule, "FREQ=MONTHLY")
    }

    func testDelayedAccountAFailureRetainsItsPreTransportDurableOperation() async {
        let requestStarted = expectation(description: "Account A request started")
        var releaseFailure: CheckedContinuation<Void, Never>?
        let vm = TasksViewModel(taskCreator: { _ in
            await withCheckedContinuation { continuation in
                releaseFailure = continuation
                requestStarted.fulfill()
            }
            throw APIError.networkError(URLError(.notConnectedToInternet))
        })
        vm.bindModelContext(context)
        vm.formTitle = "Account A private task"

        let createTask = Task { await vm.createTask() }
        await fulfillment(of: [requestStarted])

        await SyncManager.shared.suspendAndReset()
        SyncManager.shared.activate(identity: "replacement-family:replacement-user")
        releaseFailure?.resume()
        await createTask.value

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].status, .directAttempt)
        XCTAssertEqual(try! context.fetch(FetchDescriptor<FamilyTask>()).count, 1)
        XCTAssertEqual(vm.tasks.map(\.title), ["Account A private task"])
        XCTAssertEqual(
            vm.errorMessage,
            "Task was saved locally. Its exact replay state will recover automatically."
        )
        SyncManager.shared.activate(identity: "test-family:test-user")
    }

    func testTaskUpdateAttachesDocumentAndSendsSourceDocumentId() async {
        let document = sourceDocument()
        let completedAssignment = TaskAssigneeDTO(
            id: "assignment-1",
            assigneeId: "dom",
            assigneeType: "user",
            assigneeName: "Alex",
            completedAt: "2026-07-18T09:00:00Z",
            completedBy: "dom"
        )
        let original = taskDTO(
            id: "task-attach",
            title: "Read school letter",
            dueDate: "2026-07-20",
            assignees: [completedAssignment]
        )
        let updated = taskDTO(
            id: original.id,
            title: original.title,
            dueDate: original.dueDate,
            assignees: [completedAssignment],
            sourceDocument: document
        )
        var capturedTaskId: String?
        var capturedBody: TaskUpdateRequestBody?
        let vm = TasksViewModel(taskUpdater: { taskId, body in
            capturedTaskId = taskId
            capturedBody = body
            return updated
        })
        vm.bindModelContext(context)
        vm.tasks = [original]
        vm.beginEditing(original)
        vm.formSourceDocument = document

        let saved = await vm.updateTask()

        XCTAssertTrue(saved)
        XCTAssertEqual(capturedTaskId, original.id)
        XCTAssertEqual(capturedBody?.sourceDocumentId, document.id)
        XCTAssertEqual(capturedBody?.dueDate, "2026-07-20")
        XCTAssertEqual(vm.tasks.first?.sourceDocument, document)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try! encoder.encode(XCTUnwrap(capturedBody))
        let payload = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(payload["source_document_id"] as? String, document.id)
        XCTAssertEqual(Set(payload.keys), Set(["source_document_id"]))
        XCTAssertNil(payload["assignees"], "Unchanged assignments must retain completion state")
        XCTAssertNil(payload["assigned_to"])
    }

    func testTaskUpdateOmitsUntouchedFieldsAndAcceptsConcurrentDocument() async {
        let concurrentDocument = sourceDocument(id: "document-concurrent")
        let completedAssignment = TaskAssigneeDTO(
            id: "assignment-complete",
            assigneeId: "dom",
            assigneeType: "user",
            assigneeName: "Alex",
            completedAt: "2026-07-18T09:00:00Z",
            completedBy: "dom"
        )
        let original = taskDTO(
            id: "task-concurrent-document",
            title: "Original title",
            dueDate: "2026-07-20",
            recurrenceRule: "FREQ=MONTHLY;BYMONTHDAY=20",
            assignees: [completedAssignment]
        )
        let serverResult = taskDTO(
            id: original.id,
            title: "Revised title",
            dueDate: original.dueDate,
            recurrenceRule: original.recurrenceRule,
            assignees: [completedAssignment],
            sourceDocument: concurrentDocument
        )
        var capturedBody: TaskUpdateRequestBody?
        let vm = TasksViewModel(taskUpdater: { _, body in
            capturedBody = body
            return serverResult
        })
        vm.bindModelContext(context)
        vm.tasks = [original]
        vm.beginEditing(original)
        vm.formTitle = "Revised title"

        let saved = await vm.updateTask()

        XCTAssertTrue(saved)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try! encoder.encode(XCTUnwrap(capturedBody))
        let payload = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        XCTAssertEqual(payload["title"] as? String, "Revised title")
        XCTAssertEqual(Set(payload.keys), Set(["title"]))
        XCTAssertEqual(vm.tasks.first?.sourceDocumentId, concurrentDocument.id)
        XCTAssertEqual(vm.tasks.first?.sourceDocument, concurrentDocument)
        XCTAssertEqual(vm.tasks.first?.assignees.count, 1)
        XCTAssertEqual(
            vm.tasks.first?.assignees.first?.completedAt,
            completedAssignment.completedAt
        )
    }

    func testTaskUpdateOfflineOmitsUntouchedDocumentAndPreservesLocalState() async {
        let completedAssignment = TaskAssigneeDTO(
            id: "assignment-offline",
            assigneeId: "kat",
            assigneeType: "user",
            assigneeName: "Morgan",
            completedAt: "2026-07-18T10:00:00Z",
            completedBy: "kat"
        )
        let original = taskDTO(
            id: "task-stale-document-summary",
            title: "Original title",
            assignees: [completedAssignment],
            sourceDocumentId: "document-without-summary"
        )
        let vm = TasksViewModel(
            taskUpdater: { _, _ in
                throw APIError.networkError(URLError(.notConnectedToInternet))
            },
            syncManager: syncManager
        )
        vm.bindModelContext(context)
        vm.tasks = [original]
        vm.beginEditing(original)
        vm.formTitle = "Offline title"

        let saved = await vm.updateTask()

        XCTAssertTrue(saved)
        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        let payload = try! JSONSerialization.jsonObject(
            with: Data(actions[0].payload.utf8)
        ) as! [String: Any]
        XCTAssertEqual(payload["title"] as? String, "Offline title")
        XCTAssertEqual(Set(payload.keys), Set(["title"]))
        XCTAssertEqual(vm.tasks.first?.sourceDocumentId, original.sourceDocumentId)
        XCTAssertNil(vm.tasks.first?.sourceDocument)
        XCTAssertEqual(vm.tasks.first?.assignees.count, 1)
        XCTAssertEqual(
            vm.tasks.first?.assignees.first?.completedAt,
            completedAssignment.completedAt
        )
    }

    func testTaskUpdateWithNoChangesDoesNotSendRequest() async {
        let original = taskDTO(id: "task-no-change", title: "Leave unchanged")
        var updateCount = 0
        let vm = TasksViewModel(taskUpdater: { _, _ in
            updateCount += 1
            return original
        })
        vm.tasks = [original]
        vm.beginEditing(original)

        let saved = await vm.updateTask()

        XCTAssertTrue(saved)
        XCTAssertEqual(updateCount, 0)
        XCTAssertFalse(vm.isLoading)
    }

    func testTaskUpdateQueuesDocumentRemovalAsExplicitNullWhileOffline() async {
        let document = sourceDocument()
        let original = taskDTO(
            id: "task-remove-attachment",
            title: "Read school letter",
            sourceDocument: document
        )
        let vm = TasksViewModel(
            taskUpdater: { _, _ in
                throw APIError.networkError(URLError(.notConnectedToInternet))
            },
            syncManager: syncManager
        )
        vm.bindModelContext(context)
        vm.tasks = [original]
        vm.beginEditing(original)
        vm.formSourceDocument = nil

        let saved = await vm.updateTask()

        XCTAssertTrue(saved)
        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .update)
        let payload = try! JSONSerialization.jsonObject(
            with: Data(actions[0].payload.utf8)
        ) as! [String: Any]
        XCTAssertTrue(payload["source_document_id"] is NSNull)
        XCTAssertEqual(Set(payload.keys), Set(["source_document_id"]))
        XCTAssertNil(vm.tasks.first?.sourceDocumentId)
        XCTAssertNil(vm.tasks.first?.sourceDocument)
    }

    func testCalendarCreateQueuesOfflineActionOnNetworkFailure() async {
        let harness = makeStubbedSyncManager { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let vm = CalendarViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        vm.bindModelContext(context)
        vm.familyMembers = [
            FamilyMemberDTO(id: "dom", name: "Alex", memberType: "user"),
            FamilyMemberDTO(id: "kat", name: "Morgan", memberType: "user"),
            FamilyMemberDTO(id: "child-1", name: "Child One", memberType: "child"),
        ]
        vm.formTitle = "Offline event"
        vm.formAllDay = true
        vm.formStartTime = Date()
        vm.formWholeFamily = false
        vm.formParticipantIDs = ["kat", "child-1"]
        vm.formAffectedMemberIDs = ["dom"]
        vm.showingAddEvent = true
        var saveConfirmationCount = 0

        await vm.createEvent {
            saveConfirmationCount += 1
        }

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(saveConfirmationCount, 1)
        XCTAssertFalse(vm.showingAddEvent)
        XCTAssertEqual(
            vm.formTitle,
            "Offline event",
            "The form should stay intact until its presenting sheet has dismissed"
        )
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .create)
        XCTAssertEqual(actions[0].tableName, "calendar_events")
        XCTAssertFalse(vm.events.isEmpty, "Event should be optimistically added while offline")
        XCTAssertEqual(actions[0].recordId, vm.events[0].id)
        let payloadData = actions[0].payload.data(using: .utf8)!
        let payload = try! JSONSerialization.jsonObject(with: payloadData) as! [String: Any]
        XCTAssertEqual(payload["family_member_ids"] as? [String], ["kat", "child-1"])
        XCTAssertEqual(payload["affected_member_ids"] as? [String], ["dom"])
        XCTAssertNil(payload["assigned_to"] as? String)
        XCTAssertEqual(vm.events[0].affectedMemberIds, ["dom"])

        let relaunched = CalendarViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        relaunched.bindModelContext(context)
        XCTAssertEqual(relaunched.events.map(\.title), ["Offline event"])
    }

    func testMedicineLogDoseDurablyRetainsDoseAndStableActionOnNetworkFailure() async throws {
        let harness = makeStubbedSyncManager { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let vm = MedicineViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        vm.bindModelContext(context)
        vm.medicineTypes = [
            MedicineTypeDTO(
                id: "med-1",
                name: "Calpol",
                minHoursBetweenDoses: 4,
                maxDoses24h: 4,
                notes: nil,
                color: nil,
                defaultDoseAmount: "5ml",
                childId: "child-1",
                createdAt: "2026-08-10T12:00:00Z"
            )
        ]
        vm.selectedChildId = "child-1"
        vm.selectedMedicineTypeId = "med-1"
        vm.doseAmount = "5ml"

        await vm.logDose()

        let actions = try context.fetch(FetchDescriptor<OfflineAction>())
        let doses = try context.fetch(FetchDescriptor<MedicineDose>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(doses.count, 1)
        XCTAssertEqual(actions[0].operation, .create)
        XCTAssertEqual(actions[0].tableName, "medicine_doses")
        XCTAssertEqual(actions[0].status, .pending)
        XCTAssertEqual(actions[0].retryCount, 0)
        XCTAssertFalse(vm.recentDoses.isEmpty, "Dose should be optimistically added while offline")
        XCTAssertEqual(actions[0].recordId, vm.recentDoses[0].id)
        XCTAssertEqual(actions[0].id, doses[0].id)
        XCTAssertEqual(actions[0].recordId, doses[0].id)
    }

    func testMedicineCancelledRequestRetainsDoseAndPendingActionWithoutRetryInflation() async throws {
        let harness = makeStubbedSyncManager { _ in
            throw URLError(.cancelled)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let vm = MedicineViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        vm.bindModelContext(context)
        vm.medicineTypes = [
            MedicineTypeDTO(
                id: "med-1",
                name: "Calpol",
                minHoursBetweenDoses: 4,
                maxDoses24h: 4,
                notes: nil,
                color: nil,
                defaultDoseAmount: "5ml",
                childId: "child-1",
                createdAt: "2026-08-10T12:00:00Z"
            )
        ]
        vm.selectedChildId = "child-1"
        vm.selectedMedicineTypeId = "med-1"
        vm.doseAmount = "5ml"

        await vm.logDose()

        let action = try XCTUnwrap(try context.fetch(FetchDescriptor<OfflineAction>()).first)
        let dose = try XCTUnwrap(try context.fetch(FetchDescriptor<MedicineDose>()).first)
        XCTAssertEqual(action.id, dose.id)
        XCTAssertEqual(action.recordId, dose.id)
        XCTAssertEqual(action.status, .pending)
        XCTAssertEqual(action.retryCount, 0)
        XCTAssertEqual(vm.recentDoses.map(\.id), [dose.id])
        XCTAssertNil(vm.errorMessage)
    }

    func testTasksCompleteQueuesOfflineUpdateOnNetworkFailure() async {
        let vm = TasksViewModel(
            taskCompleter: { _ in
                throw APIError.networkError(URLError(.notConnectedToInternet))
            },
            syncManager: syncManager
        )
        vm.bindModelContext(context)
        let document = sourceDocument()
        vm.tasks = [
            TaskDTO(
                id: "task-1",
                title: "Existing task",
                description: nil,
                assignedTo: nil,
                dueDate: nil,
                completedAt: nil,
                category: "other",
                recurrenceRule: nil,
                priority: 2,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                createdBy: nil,
                actionableFrom: nil,
                assignees: [],
                sourceDocumentId: document.id,
                sourceDocument: document
            )
        ]

        await vm.completeTask("task-1")

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .update)
        XCTAssertEqual(actions[0].tableName, "tasks")
        XCTAssertEqual(actions[0].recordId, "task-1")
        XCTAssertNotNil(vm.tasks.first?.completedAt, "Completed timestamp should be set optimistically")
        XCTAssertEqual(vm.tasks.first?.sourceDocumentId, document.id)
        XCTAssertEqual(vm.tasks.first?.sourceDocument, document)
    }

    func testTasksDeleteQueuesOfflineDeleteOnNetworkFailure() async {
        let vm = TasksViewModel(
            taskDeleter: { _ in
                throw APIError.networkError(URLError(.notConnectedToInternet))
            },
            syncManager: syncManager
        )
        vm.bindModelContext(context)
        vm.tasks = [
            TaskDTO(
                id: "task-delete",
                title: "Delete me",
                description: nil,
                assignedTo: nil,
                dueDate: nil,
                completedAt: nil,
                category: "other",
                recurrenceRule: nil,
                priority: 1,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                createdBy: nil,
                actionableFrom: nil,
                assignees: []
            )
        ]

        await vm.deleteTask("task-delete")

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .delete)
        XCTAssertEqual(actions[0].tableName, "tasks")
        XCTAssertEqual(actions[0].recordId, "task-delete")
        XCTAssertTrue(vm.tasks.isEmpty, "Task should be removed optimistically")
    }

    func testCalendarDeleteQueuesOfflineDeleteOnNetworkFailure() async {
        let harness = makeStubbedSyncManager { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let vm = CalendarViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        vm.bindModelContext(context)
        vm.events = [
            CalendarEventDTO(
                id: "event-delete",
                title: "Delete event",
                description: nil,
                startTime: "2026-01-01T09:00:00Z",
                endTime: nil,
                allDay: false,
                recurrenceRule: nil,
                location: nil,
                familyMemberIds: nil,
                createdAt: "2026-01-01T09:00:00Z",
                updatedAt: "2026-01-01T09:00:00Z",
                createdBy: nil,
                assignedTo: nil
            )
        ]

        await vm.deleteEvent(try! XCTUnwrap(vm.events.first))

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .delete)
        XCTAssertEqual(actions[0].tableName, "calendar_events")
        XCTAssertEqual(actions[0].recordId, "event-delete")
        XCTAssertTrue(vm.events.isEmpty, "Event should be removed optimistically")
    }

    func testCalendarUpdateQueuesSparseOfflineUpdateOnNetworkFailure() async {
        let harness = makeStubbedSyncManager { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let vm = CalendarViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        vm.bindModelContext(context)
        let event = CalendarEventDTO(
            id: "event-update",
            title: "Doctor",
            description: "Bring forms",
            startTime: "2026-01-01T09:00:00Z",
            endTime: "2026-01-01T09:30:00Z",
            allDay: false,
            recurrenceRule: "FREQ=WEEKLY;INTERVAL=2;COUNT=6",
            location: nil,
            familyMemberIds: ["kat", "child"],
            affectedMemberIds: ["dom"],
            createdAt: "2026-01-01T08:00:00Z",
            updatedAt: "2026-01-01T08:00:00Z",
            createdBy: nil,
            assignedTo: nil
        )
        vm.events = [event]
        vm.beginEditing(event)
        vm.formTitle = "Doctor appointment"

        await vm.updateEvent()

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .update)
        XCTAssertEqual(actions[0].recordId, "event-update")
        let payload = try! XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(actions[0].payload.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["title"] as? String, "Doctor appointment")
        XCTAssertNil(payload["start_time"])
        XCTAssertNil(payload["recurrence_rule"])
        XCTAssertNil(payload["family_member_ids"])
        XCTAssertEqual(vm.events.first?.recurrenceRule, event.recurrenceRule)
    }

    func testMedicineAddTypeQueuesOfflineCreateOnNetworkFailure() async {
        let harness = makeStubbedSyncManager { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            harness.client.clearSession()
            harness.defaults.removePersistentDomain(forName: harness.suiteName)
        }
        let vm = MedicineViewModel(
            apiClient: harness.client,
            syncManager: harness.manager
        )
        vm.bindModelContext(context)
        vm.selectedChildId = "child-1"
        vm.typeName = "Calpol"
        vm.typeMinHours = 4
        vm.typeMaxDoses = 4

        await vm.addMedicineType()

        let actions = try! context.fetch(FetchDescriptor<OfflineAction>())
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].operation, .create)
        XCTAssertEqual(actions[0].tableName, "medicine_types")
        XCTAssertFalse(vm.medicineTypes.isEmpty, "Medicine type should be added optimistically")
        XCTAssertEqual(actions[0].recordId, vm.medicineTypes[0].id)
    }
}
