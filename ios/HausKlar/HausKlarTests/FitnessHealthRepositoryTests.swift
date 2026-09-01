import Foundation
import GRDB
import UIKit
import XCTest
@testable import HausKlar

final class FitnessHealthRepositoryTests: XCTestCase {
    private var directory: URL!
    private var database: FitnessDatabase!
    private var repository: FitnessHealthRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitnessHealthTests-\(UUID().uuidString)",isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        database = FitnessDatabase()
        try database.activateForTesting(
            identity: "family-a:user-a",storeURL: directory.appendingPathComponent("a/fitness.sqlite")
        )
        repository = FitnessHealthRepository(database: database,clientId: "test-client")
    }

    override func tearDownWithError() throws {
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMalformedProgressPhotoPayloadFailsClosedWithoutDroppingQueueRow() async throws {
        let photoId = UUID().uuidString
        let assetId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql:"""
                    INSERT INTO fitness_progress_photos
                    (id,captured_at,pose,original_asset_id,original_state,
                     metadata_acknowledged,revision,client_updated_at,payload_json)
                    VALUES (?,?,'front',?,'pending',0,0,?,'{')
                    """,
                arguments:[photoId,now,assetId,now]
            )
            try db.execute(
                sql:"""
                    INSERT INTO fitness_private_file_uploads
                    (asset_id,domain_entity_id,asset_kind,storage_class,relative_path,
                     original_filename,media_type,byte_count,state,created_at)
                    VALUES (?,?,'progress_photo','private_required',?,
                            'progress-front.jpg','image/jpeg',128,'pending_upload',?)
                    """,
                arguments:[
                    assetId,photoId,
                    "PrivateRequired/ProgressPhotos/\(assetId.lowercased()).jpg",now,
                ]
            )
        }

        do {
            _ = try await repository.pendingProgressPhotos()
            XCTFail("A malformed queued photo must fail the complete outbox read")
        } catch is DecodingError {
            // Expected.
        }
        do {
            _ = try await repository.progressPhotos()
            XCTFail("A malformed photo must fail the complete gallery read")
        } catch is DecodingError {
            // Expected.
        }
        XCTAssertEqual(
            try database.read { db in
                try Int.fetchOne(
                    db,sql:"SELECT COUNT(*) FROM fitness_private_file_uploads WHERE asset_id=?",
                    arguments:[assetId]
                ) ?? 0
            },
            1
        )
    }

    func testSourceDomainOutboxAndAnchorCommitAtomicallyAndExactIdentityIsIdempotent() async throws {
        let sample = bodySample(uuid: "body-1",bundle: "com.withings.wiscale2",externalId: "weighing-1")
        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [sample],deletions: [],archivedAnchor: Data([1])
        )

        let first = try database.read { db in
            (
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_external_source_records") ?? 0,
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_body_measurements") ?? 0,
                try String.fetchAll(db,sql: "SELECT entity_type FROM fitness_outbox ORDER BY rowid"),
                try Data.fetchOne(db,sql: "SELECT anchor_data FROM fitness_healthkit_query_state")
            )
        }
        XCTAssertEqual(first.0,1)
        XCTAssertEqual(first.1,1)
        XCTAssertEqual(first.2,[FitnessEntityType.sourceRecord.rawValue,FitnessEntityType.bodyMeasurement.rawValue])
        XCTAssertEqual(first.3,Data([1]))
        let displayed = try await FitnessRepository(
            database: database,deviceId: "test-client"
        ).bodyMeasurements(limit: 10)
        let sourceId = try database.read { db in
            try String.fetchOne(db,sql: "SELECT id FROM fitness_external_source_records")
        }
        XCTAssertEqual(displayed.first?.sourceRecordId,sourceId)
        XCTAssertEqual(displayed.first?.sourceDetails?.transportKey,"healthkit")
        XCTAssertEqual(displayed.first?.sourceDetails?.originProviderKey,"withings")
        XCTAssertEqual(displayed.first?.sourceDetails?.sourceNamespace,"com.withings.wiscale2")

        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [sample],deletions: [],archivedAnchor: Data([2])
        )
        let second = try database.read { db in
            (
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_external_source_records") ?? 0,
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_body_measurements") ?? 0,
                try Data.fetchOne(db,sql: "SELECT anchor_data FROM fitness_healthkit_query_state")
            )
        }
        XCTAssertEqual(second.0,1,"The exact source key must not create another provenance row")
        XCTAssertEqual(second.1,1,"A predicate reset or replay must not duplicate the domain reading")
        XCTAssertEqual(second.2,Data([2]))
    }

    func testOutboxFailureRollsBackSourceDomainAndNewAnchor() async throws {
        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [],deletions: [],archivedAnchor: Data([7])
        )
        try database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_health_outbox BEFORE INSERT ON fitness_outbox
                BEGIN SELECT RAISE(ABORT,'test outbox failure'); END;
                """)
        }

        do {
            try await repository.applyHealthKitBatch(
                kind: .bodyMass,samples: [bodySample(uuid: "body-fail")],deletions: [],
                archivedAnchor: Data([8])
            )
            XCTFail("The injected local failure should abort the complete anchor transaction")
        } catch {}

        let state = try database.read { db in
            (
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_external_source_records") ?? 0,
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_body_measurements") ?? 0,
                try Data.fetchOne(db,sql: "SELECT anchor_data FROM fitness_healthkit_query_state")
            )
        }
        XCTAssertEqual(state.0,0)
        XCTAssertEqual(state.1,0)
        XCTAssertEqual(state.2,Data([7]),"A failed local batch must leave the archived query anchor unchanged")
    }

    func testRejectedWorkoutAcknowledgementRetainsDurableReplay() async throws {
        let request = workoutRequest()
        try await repository.stageWorkoutHealthKitPage(
            requests: [request],deletedWorkoutUuids: [],archivedAnchor: Data([7])
        )
        let pending = try await repository.pendingWorkoutImports()
        let item = try XCTUnwrap(pending.first)
        do {
            try await repository.acknowledgeWorkoutImport(
                itemId: item.id,request: request,
                response: .init(status: "failed",sourceRecordId: "source",activityId: nil,deleted: false)
            )
            XCTFail("A non-contract response must leave its replay record durable")
        } catch {}
        let state = try await repository.anchorState(kind: .workout)
        XCTAssertEqual(state.anchorData,Data([7]))
        let retainedIds = try await repository.pendingWorkoutImports().map(\.id)
        XCTAssertEqual(retainedIds,[item.id])
        let sourceCount = try database.read { db in
            try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_healthkit_workout_sources") ?? 0
        }
        XCTAssertEqual(sourceCount,0)
    }

    func testAcknowledgedWorkoutCommitsSourceReceiptAndRemovesReplayTogether() async throws {
        let request=FitnessHealthKitWorkoutImport(
            sourceBundleIdentifier:"com.apple.health",workoutUuid:UUID().uuidString,
            originProviderKey:"apple",externalUuid:"watch-workout",sourceName:"Apple Watch",
            sourceDeviceIdentifier:"watch",productType:"Watch7,1",sportKey:"running",subSportKey:nil,
            title:"Run",startedAtUtc:"2026-08-03T08:00:00.000Z",
            endedAtUtc:"2026-08-03T08:30:00.000Z",durationS:1_800,distanceM:5_000,
            energyKcal:350,localTimezone:"Europe/Berlin",deleted:false
        )
        try await repository.stageWorkoutHealthKitPage(
            requests: [request],deletedWorkoutUuids: [],archivedAnchor: Data([9])
        )
        let pending = try await repository.pendingWorkoutImports()
        let item = try XCTUnwrap(pending.first)
        try await repository.acknowledgeWorkoutImport(
            itemId: item.id,request: request,
            response: .init(status:"created",sourceRecordId:"source-1",activityId:"activity-1",deleted:false)
        )
        let state=try await repository.anchorState(kind:.workout)
        XCTAssertEqual(state.anchorData,Data([9]))
        let remaining = try await repository.pendingWorkoutImports()
        XCTAssertTrue(remaining.isEmpty)
        let sources=try await repository.workoutSources(workoutUuid:request.workoutUuid)
        let source=try XCTUnwrap(sources.first)
        XCTAssertEqual(source.sourceBundleIdentifier,"com.apple.health")
        XCTAssertEqual(source.externalUuid,"watch-workout")
    }

    func testBundleIdentifierParticipatesInExactHealthKitSourceIdentity() async throws {
        let uuid = "provider-local-uuid"
        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [
                bodySample(uuid: uuid,bundle: "com.withings.wiscale2"),
                bodySample(uuid: uuid,bundle: "com.apple.health"),
            ],deletions: [],archivedAnchor: Data([1])
        )
        let identities = try database.read { db in
            try Row.fetchAll(
                db,sql: "SELECT source_namespace,source_object_id FROM fitness_external_source_records ORDER BY source_namespace"
            ).map { "\($0["source_namespace"] as String):\($0["source_object_id"] as String)" }
        }
        XCTAssertEqual(identities,["com.apple.health:\(uuid)","com.withings.wiscale2:\(uuid)"])
    }

    func testDeletionIsScopedByHealthKitTypeAndUsesEmptyWirePayload() async throws {
        let sharedUUID = "same-hk-uuid"
        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [bodySample(uuid: sharedUUID)],deletions: [],archivedAnchor: Data([1])
        )
        try await repository.applyHealthKitBatch(
            kind: .restingHeartRate,samples: [recoverySample(uuid: sharedUUID)],deletions: [],archivedAnchor: Data([1])
        )
        try database.write { db in try db.execute(sql: "DELETE FROM fitness_outbox") }

        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [],
            deletions: [FitnessHealthKitDeletedObject(kind: .bodyMass,sourceObjectId: sharedUUID)],
            archivedAnchor: Data([2])
        )

        let result = try database.read { db in
            (
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_body_measurements WHERE deleted_at IS NOT NULL") ?? 0,
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_recovery_observations WHERE deleted_at IS NULL") ?? 0,
                try String.fetchAll(db,sql: "SELECT payload_json FROM fitness_outbox WHERE operation='delete' ORDER BY rowid")
            )
        }
        XCTAssertEqual(result.0,1)
        XCTAssertEqual(result.1,1,"A UUID collision in another HealthKit type must remain untouched")
        XCTAssertEqual(result.2,["{}","{}"],"Fitness delete mutations use the server's empty-payload convention")
    }

    func testContiguousSleepStagesFormOneSessionAndDeletingAStageRebuildsIt() async throws {
        let start = Date(timeIntervalSince1970: 1_785_620_400)
        let first = sleepSample(uuid: "sleep-core",stage: "core",start: start,end: start.addingTimeInterval(3_600))
        let second = sleepSample(
            uuid: "sleep-rem",stage: "rem",start: start.addingTimeInterval(3_600),
            end: start.addingTimeInterval(5_400)
        )
        try await repository.applyHealthKitBatch(
            kind: .sleepAnalysis,samples: [first,second],deletions: [],archivedAnchor: Data([1])
        )
        let grouped = try await repository.localSleepSessions()
        XCTAssertEqual(grouped.count,1)
        XCTAssertEqual(grouped[0].sourceStages?.count,2)
        XCTAssertEqual(Set(grouped[0].sourceStages?.compactMap(\.sourceRecordId) ?? []).count,2)
        XCTAssertEqual(grouped[0].durationS,5_400,accuracy: 0.01)

        try await repository.applyHealthKitBatch(
            kind: .sleepAnalysis,samples: [],
            deletions: [FitnessHealthKitDeletedObject(kind: .sleepAnalysis,sourceObjectId: "sleep-core")],
            archivedAnchor: Data([2])
        )
        let rebuilt = try await repository.localSleepSessions()
        XCTAssertEqual(rebuilt.count,1)
        XCTAssertEqual(rebuilt[0].sourceStages?.map(\.stage),["rem"])
        XCTAssertEqual(rebuilt[0].durationS,1_800,accuracy: 0.01)

        try await repository.applyHealthKitBatch(
            kind: .sleepAnalysis,samples: [],
            deletions: [FitnessHealthKitDeletedObject(kind: .sleepAnalysis,sourceObjectId: "sleep-rem")],
            archivedAnchor: Data([3])
        )
        let emptySleepSessions=try await repository.localSleepSessions()
        XCTAssertTrue(emptySleepSessions.isEmpty)
    }

    func testDirectProviderAndHealthKitCopiesRemainButConfiguredPriorityChoosesOneCanonical() async throws {
        let now = FitnessDatabase.dateString(Date(timeIntervalSince1970: 1_785_620_400))
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_external_source_records
                    (id,record_kind,sample_type,transport_key,origin_provider_key,source_namespace,
                     source_object_id,external_object_id,domain_entity_type,domain_entity_id,state,created_at,updated_at)
                    VALUES ('direct-source','body_measurement','provider.body_mass','direct','withings',
                            'withings-api','direct-1','weighing-1','body_measurement','direct-body','active',?,?)
                    """,arguments: [now,now]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_body_measurements
                    (id,measured_at,weight_kg,source,is_canonical,revision,client_updated_at,origin_device_id,
                     source_record_id,canonical_state,origin_provider_key,transport_key,source_namespace,
                     external_object_id,measurement_quality)
                    VALUES ('direct-body',?,80.0,'imported',1,0,?,'server','direct-source','canonical',
                            'withings','direct','withings-api','weighing-1','measured')
                    """,arguments: [now,now]
            )
        }
        let hk = bodySample(
            uuid: "hk-copy",bundle: "com.withings.wiscale2",externalId: "weighing-1",
            date: Date(timeIntervalSince1970: 1_785_620_400)
        )
        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [hk],deletions: [],archivedAnchor: Data([1])
        )
        var canonical = try database.read { db in
            try String.fetchAll(db,sql: "SELECT id FROM fitness_body_measurements WHERE is_canonical=1 AND deleted_at IS NULL")
        }
        XCTAssertEqual(canonical,["direct-body"])
        XCTAssertEqual(try database.read { db in try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_body_measurements") },2)

        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_source_priorities
                    (id,metric_key,origin_provider_key,transport_key,source_namespace,priority,revision,updated_at)
                    VALUES ('prefer-hk','body.weight_kg','withings','healthkit','com.withings.wiscale2',200,1,?)
                    """,arguments: [now]
            )
        }
        try await repository.applyHealthKitBatch(
            kind: .bodyMass,samples: [hk],deletions: [],archivedAnchor: Data([2])
        )
        canonical = try database.read { db in
            try String.fetchAll(db,sql: "SELECT id FROM fitness_body_measurements WHERE is_canonical=1 AND deleted_at IS NULL")
        }
        let healthKitId = try database.read { db in
            try String.fetchOne(db,sql: "SELECT id FROM fitness_body_measurements WHERE transport_key='healthkit'")
        }
        XCTAssertEqual(canonical,[healthKitId].compactMap { $0 })
    }

    func testRemoteSourcePriorityMaterialisesForLaterLocalReranking() async throws {
        let priorityId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())
        let syncRepository = FitnessRepository(database: database,deviceId: "test-client")
        let response = FitnessSyncResponse(
            status: "ok",currentSyncProtocolVersion: 1,currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1,accepted: [],ackedMutationIds: [],
            rejectedMutations: [],changes: [FitnessSyncChange(
                sequence: 1,entityType: FitnessEntityType.sourcePriority.rawValue,
                entityId: priorityId,revision: 3,operation: "upsert",data: [
                    "id": .string(priorityId),"metric_key": .string("body.weight_kg"),
                    "origin_provider_key": .string("withings"),"transport_key": .string("healthkit"),
                    "source_namespace": .string("com.withings.wiscale2"),"priority": .int(200),
                    "updated_at": .string(now),
                ],changedAt: now
            )],redirects: [],notices: [],nextCursor: 1
        )
        try await syncRepository.applySync(response,sentMutationIds: [])
        let stored = try database.read { db in
            try Row.fetchOne(db,sql: "SELECT * FROM fitness_source_priorities WHERE id=?",arguments: [priorityId])
        }
        XCTAssertEqual(stored?["priority"] as Int?,200)
        XCTAssertEqual(stored?["revision"] as Int?,3)
    }

    func testCanonicalOverrideUsesExactEndpointAndSurvivesLocalHealthKitReranking() async throws {
        let firstId=UUID().uuidString
        let selectedId=UUID().uuidString
        let firstSourceId=UUID().uuidString
        let selectedSourceId=UUID().uuidString
        let measured=Date(timeIntervalSince1970: 1_785_620_400)
        let now=FitnessDatabase.dateString(measured)
        try database.write { db in
            for source in [
                (firstSourceId,"direct","withings-api","direct-object"),
                (selectedSourceId,"provider_api","withings-api-v2","selected-object"),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_external_source_records
                        (id,record_kind,sample_type,transport_key,origin_provider_key,source_namespace,
                         source_object_id,external_object_id,domain_entity_type,domain_entity_id,state,
                         created_at,updated_at)
                        VALUES (?,'body_measurement','provider.body_mass',?,'withings',?,?,
                                'shared-weighing','body_measurement',?,'active',?,?)
                        """,arguments: [source.0,source.1,source.2,source.3,
                                         source.0 == firstSourceId ? firstId : selectedId,now,now]
                )
            }
            for measurement in [
                (firstId,firstSourceId,"direct","withings-api",true,"canonical",nil),
                (selectedId,selectedSourceId,"provider_api","withings-api-v2",false,"duplicate",firstId),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_body_measurements
                        (id,measured_at,weight_kg,source,is_canonical,revision,client_updated_at,
                         origin_device_id,source_record_id,canonical_state,duplicate_of_measurement_id,
                         origin_provider_key,transport_key,source_namespace,external_object_id,
                         measurement_quality,metric_key,value_number,unit_key)
                        VALUES (?,?,80.0,'imported',?,0,?,'server',?,?,?,?,?,?,
                                'shared-weighing','measured','body.weight_kg',80.0,'kg')
                        """,arguments: [measurement.0,now,measurement.4,now,measurement.1,
                                         measurement.5,measurement.6,"withings",measurement.2,measurement.3]
                )
            }
        }

        FitnessHealthURLProtocol.install { request in
            XCTAssertTrue(request.url?.path.hasSuffix(
                "/fitness/body/measurements/\(selectedId)/canonical-override"
            ) == true)
            if request.httpMethod == "POST" {
                XCTAssertNil(request.httpBody,"Canonical selection has no request body")
            } else {
                XCTAssertEqual(request.httpMethod,"DELETE")
            }
            let selected=request.httpMethod == "POST"
            let groupIds=try self.database.read { db in
                try String.fetchAll(
                    db,sql: "SELECT id FROM fitness_body_measurements WHERE metric_key='body.weight_kg' AND deleted_at IS NULL"
                )
            }
            let object: [String:Any] = [
                "canonical_measurement_id":selected ? selectedId : firstId,
                "group_member_ids":groupIds,
                "manual_override":selected,
            ]
            let response=HTTPURLResponse(
                url: try XCTUnwrap(request.url),statusCode: 200,httpVersion: nil,
                headerFields: ["Content-Type":"application/json"]
            )!
            return (response,try JSONSerialization.data(withJSONObject: object))
        }
        let configuration=URLSessionConfiguration.ephemeral
        configuration.protocolClasses=[FitnessHealthURLProtocol.self]
        let client=APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL="https://canonical-override-\(UUID().uuidString).example.test/api"
        _=client.installSession(
            identity: "family-a:user-a",accessToken: "access",refreshToken: "refresh"
        )
        defer { client.clearSession() }
        let localRepository=FitnessRepository(database: database,deviceId: "test-client")
        let service=FitnessRecoveryService(
            repository: repository,apiClient: client,fitnessRepository: localRepository,
            database: database
        )
        await service.activate(identity: "family-a:user-a")

        _=try await service.selectCanonicalBodyMeasurement(selectedId)
        var rows=try await localRepository.bodyMeasurements(
            limit: 10,includeDuplicates: true,metricKey: "body.weight_kg"
        )
        XCTAssertTrue(rows.first { $0.id == selectedId }?.isCanonical == true)
        XCTAssertTrue(rows.first { $0.id == selectedId }?.manualCanonicalOverride == true)

        try await repository.applyHealthKitBatch(
            kind: .bodyMass,
            samples: [bodySample(
                uuid: "healthkit-copy",bundle: "com.withings.wiscale2",
                externalId: "shared-weighing",date: measured
            )],
            deletions: [],archivedAnchor: Data([9])
        )
        rows=try await localRepository.bodyMeasurements(
            limit: 10,includeDuplicates: true,metricKey: "body.weight_kg"
        )
        XCTAssertTrue(rows.first { $0.id == selectedId }?.isCanonical == true)
        XCTAssertTrue(rows.first { $0.id == selectedId }?.manualCanonicalOverride == true)

        _=try await service.clearCanonicalBodyMeasurementOverride(selectedId)
        rows=try await localRepository.bodyMeasurements(
            limit: 10,includeDuplicates: true,metricKey: "body.weight_kg"
        )
        XCTAssertTrue(rows.first { $0.id == firstId }?.isCanonical == true)
        XCTAssertFalse(rows.contains { $0.manualCanonicalOverride })
        await service.suspend()
    }

    func testProgressOriginalSurvivesUntilUploadAndMetadataAcknowledgements() async throws {
        let artifact = try makeProgressPhotoArtifact()
        defer { FitnessProgressPhotoPreparation.removeArtifact(artifact) }
        let pending = try await repository.createProgressPhoto(
            jpegFileURL: artifact.fileURL,capturedAt: Date(),pose: .front,
            bodyWeightKg: 80,phaseId: nil,notes: "Durability test",clientId: "test-client"
        )
        let localURL = try await repository.localOriginalURL(assetId: pending.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertEqual(
            pending.byteCount,
            try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(at: localURL)
        )
        let initial = try database.read { db in
            (
                try String.fetchOne(db,sql: "SELECT storage_class FROM fitness_private_file_uploads WHERE asset_id=?",arguments: [pending.id]),
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_progress_photos") ?? 0,
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_outbox WHERE entity_type='progress_photo'") ?? 0
            )
        }
        XCTAssertEqual(initial.0,"private_required")
        XCTAssertEqual(initial.1,1)
        XCTAssertEqual(initial.2,1)

        try await repository.markPhotoUploadAcknowledged(
            assetId: pending.id,
            result: FitnessPrivateAssetUploadResult(
                assetId: pending.id,state: "staged",storageClass: "private_required",uploadAcknowledged: true
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path),"Upload acknowledgement alone is insufficient")

        var saved = pending.photo
        saved.metadataAcknowledged = true
        saved.originalState = "ready"
        try await repository.acknowledgePhotoMetadata(assetId: pending.id,photo: saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        let remainingPending=try await repository.pendingProgressPhotos()
        let savedPhotoIds=try await repository.progressPhotos().map(\.id)
        XCTAssertTrue(remainingPending.isEmpty)
        XCTAssertEqual(savedPhotoIds,[pending.photo.id])
    }

    func testProgressPendingFilesStayInTheirFitnessIdentityNamespace() async throws {
        let artifact = try makeProgressPhotoArtifact()
        defer { FitnessProgressPhotoPreparation.removeArtifact(artifact) }
        let pending = try await repository.createProgressPhoto(
            jpegFileURL: artifact.fileURL,capturedAt: Date(),pose: .back,
            bodyWeightKg: nil,phaseId: nil,notes: nil,clientId: "test-client"
        )
        let aURL = try await repository.localOriginalURL(assetId: pending.id)
        database.suspend()
        try database.activateForTesting(
            identity: "family-a:user-b",storeURL: directory.appendingPathComponent("b/fitness.sqlite")
        )
        let otherIdentityPending=try await repository.pendingProgressPhotos()
        XCTAssertTrue(otherIdentityPending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aURL.path),"Switching profiles must not purge profile A")

        database.suspend()
        try database.activateForTesting(
            identity: "family-a:user-a",storeURL: directory.appendingPathComponent("a/fitness.sqlite")
        )
        let restoredPendingIds=try await repository.pendingProgressPhotos().map(\.id)
        XCTAssertEqual(restoredPendingIds,[pending.id])
    }

    func testMeasurementTrendUsesElapsedTimeAndPreservesRawValues() throws {
        let firstDate = try XCTUnwrap(ISODateParser.parse("2026-01-01T08:00:00Z"))
        let secondDate = try XCTUnwrap(ISODateParser.parse("2026-01-08T08:00:00Z"))
        let measurements = [
            trendMeasurement(id: "first",metric: "body.weight_kg",date: firstDate,value: 80),
            trendMeasurement(id: "second",metric: "body.weight_kg",date: secondDate,value: 70),
        ]

        let history = FitnessMeasurementHistoryBuilder.make(
            metric: .weight,bodyMeasurements: measurements,recoveryObservations: []
        )

        XCTAssertEqual(history.sampleCount,2)
        XCTAssertEqual(history.series.first?.points.map(\.rawValue),[80,70])
        XCTAssertEqual(try XCTUnwrap(history.series.first?.points.first?.trendValue),80,accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(history.series.first?.points.last?.trendValue),75,accuracy: 0.0001)
    }

    func testMeasurementTrendAveragesMultipleReadingsOnTheSameDay() throws {
        let morning = try XCTUnwrap(ISODateParser.parse("2026-02-01T07:00:00Z"))
        let evening = try XCTUnwrap(ISODateParser.parse("2026-02-01T19:00:00Z"))
        let history = FitnessMeasurementHistoryBuilder.make(
            metric: .bodyFat,
            bodyMeasurements: [
                trendMeasurement(id: "morning",metric: "body.body_fat_pct",date: morning,value: 20),
                trendMeasurement(id: "evening",metric: "body.body_fat_pct",date: evening,value: 22),
            ],
            recoveryObservations: []
        )

        XCTAssertEqual(history.series.first?.points.map(\.trendValue),[21,21])
        XCTAssertEqual(history.series.first?.points.map(\.rawValue),[20,22])
    }

    func testBloodPressureHistoryKeepsSystolicAndDiastolicSeparate() {
        let observations = [
            FitnessRecoveryObservationDTO(
                id: "sys",metricKey: "vitals.blood_pressure_systolic_mmhg",
                observedAtUtc: "2026-03-01T09:00:00.000Z",valueNumber: 122,valueText: nil,
                unitKey: "mmHg",sourceQuality: "direct",sourceRecordId: nil,source: nil,
                notes: nil,revision: 1,createdAt: nil,updatedAt: nil,deletedAt: nil
            ),
            FitnessRecoveryObservationDTO(
                id: "dia",metricKey: "vitals.blood_pressure_diastolic_mmhg",
                observedAtUtc: "2026-03-01T09:00:00.000Z",valueNumber: 78,valueText: nil,
                unitKey: "mmHg",sourceQuality: "direct",sourceRecordId: nil,source: nil,
                notes: nil,revision: 1,createdAt: nil,updatedAt: nil,deletedAt: nil
            ),
        ]

        let history = FitnessMeasurementHistoryBuilder.make(
            metric: .bloodPressure,bodyMeasurements: [],recoveryObservations: observations
        )

        XCTAssertEqual(history.series.map(\.key),["systolic","diastolic"])
        XCTAssertEqual(history.series[0].points.first?.rawValue,122)
        XCTAssertEqual(history.series[1].points.first?.rawValue,78)
        XCTAssertEqual(history.unit,"mmHg")
    }

    func testWithingsHistoryContractDecodesSnakeCaseAPIResponse() throws {
        let data = Data("""
            {
              "metric":"weight","title":"Weight","unit":"kg",
              "smoothing_method":"time_weighted_exponential","smoothing_half_life_days":7,
              "series":[{"key":"weight","label":"Weight","unit":"kg","points":[{
                "id":"reading-1","measured_at_utc":"2026-04-01T07:00:00Z",
                "raw_value":81.2,"trend_value":80.9,"source_label":"Withings scale"
              }]}],
              "sample_count":1,"last_updated_at":"2026-04-01T07:00:01Z"
            }
            """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let value = try decoder.decode(FitnessMeasurementHistoryDTO.self,from: data)

        XCTAssertEqual(value.metric,.weight)
        XCTAssertEqual(value.series.first?.points.first?.rawValue,81.2)
        XCTAssertNotNil(value.series.first?.points.first?.measuredAt)
    }

    private func makeProgressPhotoArtifact() throws -> FitnessProgressPhotoArtifact {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32,height: 24)).image {
            UIColor.systemBlue.setFill()
            $0.fill(CGRect(x: 0,y: 0,width: 32,height: 24))
        }
        return try FitnessProgressPhotoPreparation.prepareCameraImage(
            image,
            root: directory.appendingPathComponent("prepared-progress-photos",isDirectory: true)
        )
    }

    private func bodySample(
        uuid: String,bundle: String = "com.apple.health",externalId: String? = nil,
        date: Date = Date(timeIntervalSince1970: 1_785_620_400)
    ) -> FitnessHealthKitSample {
        FitnessHealthKitSample(
            kind: .bodyMass,domainKind: .bodyMeasurement,startDate: date,endDate: date,
            value: 80,unitKey: "kg",sleepStage: nil,
            provenance: provenance(uuid: uuid,bundle: bundle,externalId: externalId)
        )
    }

    private func workoutRequest() -> FitnessHealthKitWorkoutImport {
        FitnessHealthKitWorkoutImport(
            sourceBundleIdentifier: "com.apple.health",workoutUuid: UUID().uuidString,
            originProviderKey: "apple",externalUuid: nil,sourceName: "Health",
            sourceDeviceIdentifier: nil,productType: nil,sportKey: "running",subSportKey: nil,
            title: "Run",startedAtUtc: "2026-08-03T08:00:00.000Z",
            endedAtUtc: "2026-08-03T08:30:00.000Z",durationS: 1_800,distanceM: 5_000,
            energyKcal: 350,localTimezone: "Europe/Berlin",deleted: false
        )
    }

    private func recoverySample(uuid: String) -> FitnessHealthKitSample {
        let date = Date(timeIntervalSince1970: 1_785_620_400)
        return FitnessHealthKitSample(
            kind: .restingHeartRate,domainKind: .recoveryObservation,startDate: date,endDate: date,
            value: 52,unitKey: "bpm",sleepStage: nil,provenance: provenance(uuid: uuid,bundle: "com.apple.health")
        )
    }

    private func sleepSample(uuid: String,stage: String,start: Date,end: Date) -> FitnessHealthKitSample {
        FitnessHealthKitSample(
            kind: .sleepAnalysis,domainKind: .sleepSession,startDate: start,endDate: end,
            value: nil,unitKey: nil,sleepStage: stage,
            provenance: provenance(uuid: uuid,bundle: "com.apple.health")
        )
    }

    private func provenance(uuid: String,bundle: String,externalId: String? = nil) -> FitnessHealthKitProvenance {
        FitnessHealthKitProvenance(
            sourceBundleIdentifier: bundle,sourceObjectId: uuid,sourceName: "Test source",
            productType: "Watch",originProviderKey: bundle.contains("withings") ? "withings" : "apple",
            externalObjectId: externalId,sourceDeviceIdentifier: "test-device",
            device: ["model": "Test"],metadata: externalId.map { ["external_uuid": .string($0)] } ?? [:]
        )
    }

    private func trendMeasurement(
        id: String,metric: String,date: Date,value: Double
    ) -> FitnessBodyMeasurement {
        FitnessBodyMeasurement(
            id: id,metricKey: metric,measuredAt: date,value: value,
            unitKey: metric == "body.body_fat_pct" ? "%" : "kg",notes: nil,
            measurementQuality: "direct",source: .imported,isCanonical: true,
            revision: 1,updatedAt: date
        )
    }
}

private final class FitnessHealthURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self,didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response,data) = try handler(request)
            client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self,didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self,didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
