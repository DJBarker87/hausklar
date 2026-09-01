import XCTest
import GRDB
@testable import HausKlar

final class FitnessRepositoryTests: XCTestCase {
    private var directory: URL!
    private var database: FitnessDatabase!
    private var repository: FitnessRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = FitnessDatabase()
        try database.activateForTesting(storeURL: directory.appendingPathComponent("fitness.sqlite"))
        repository = FitnessRepository(database: database, deviceId: "test-device")
    }

    override func tearDownWithError() throws {
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testRejectedFoodLogLeavesNoPhantomDiaryEntry() async throws {
        let entryId = UUID().uuidString
        let mutationId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_food_log_entries
                    (id,food_name,logged_at,nutrition_date,meal,revision,client_updated_at,origin_device_id)
                    VALUES (?,?,?,?,?,3,?,'test-device')
                    """,
                arguments: [entryId, "Oats", now, "2026-08-02", "breakfast", now]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_outbox
                    (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                     base_revision,payload_json,created_at_client)
                    VALUES (?,?,?,'upsert',1,3,'{}',?)
                    """,
                arguments: [mutationId, FitnessEntityType.foodLogEntry.rawValue, entryId, now]
            )
        }

        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [FitnessSyncRejected(
                mutationId: mutationId, entityId: entryId, code: "validation_failed",
                message: "That diary entry could not be saved.", retryable: false,
                targetId: nil, targetSummary: nil, noticeId: nil
            )],
            changes: [], redirects: [], notices: [], nextCursor: 1
        )

        try await repository.applySync(response, sentMutationIds: [mutationId])

        let (removedAt, queued, rejections) = try database.read { db in
            (
                try String.fetchOne(
                    db, sql: "SELECT deleted_at FROM fitness_food_log_entries WHERE id=?",
                    arguments: [entryId]
                ),
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_outbox") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_sync_rejections") ?? 0
            )
        }
        XCTAssertNotNil(removedAt, "A rejected entry must not stay in the diary")
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(rejections, 1, "The attempted values stay recoverable")
    }

    func testRejectedEditReturnsTheEntryToItsServerState() async throws {
        let entryId = UUID().uuidString
        let versionId = UUID().uuidString
        let mutationId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())
        let serverPayload = """
            {
              "id": "\(entryId)",
              "food_version_id": "\(versionId)",
              "logged_at_utc": "\(now)",
              "nutrition_date": "2026-08-02",
              "meal_key": "breakfast",
              "entered_amount": 30,
              "entered_unit": "g",
              "canonical_amount": 30,
              "canonical_unit": "g",
              "calories_kcal": 114
            }
            """
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_food_log_entries
                    (id,food_name,logged_at,nutrition_date,meal,revision,client_updated_at,origin_device_id)
                    VALUES (?,?,?,?,?,3,?,'test-device')
                    """,
                arguments: [entryId, "Oats", now, "2026-08-02", "breakfast", now]
            )
            // The server's last reported state for this entry.
            try db.execute(
                sql: """
                    INSERT INTO fitness_remote_entities
                    (entity_type,entity_id,revision,operation,payload_json,changed_at,sequence)
                    VALUES (?,?,?,'upsert',?,?,1)
                    """,
                arguments: [
                    FitnessEntityType.foodLogEntry.rawValue, entryId, 4, serverPayload, now,
                ]
            )
            // An optimistic local edit the server then refused.
            try db.execute(
                sql: "UPDATE fitness_food_log_entries SET entered_amount=300,kcal=1140 WHERE id=?",
                arguments: [entryId]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_outbox
                    (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                     base_revision,payload_json,created_at_client)
                    VALUES (?,?,?,'upsert',1,3,'{}',?)
                    """,
                arguments: [mutationId, FitnessEntityType.foodLogEntry.rawValue, entryId, now]
            )
        }

        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [FitnessSyncRejected(
                mutationId: mutationId, entityId: entryId, code: "validation_failed",
                message: "That portion could not be saved.", retryable: false,
                targetId: nil, targetSummary: nil, noticeId: nil
            )],
            changes: [], redirects: [], notices: [], nextCursor: 1
        )

        try await repository.applySync(response, sentMutationIds: [mutationId])

        let (amount, removedAt) = try database.read { db in
            (
                try Double.fetchOne(
                    db, sql: "SELECT entered_amount FROM fitness_food_log_entries WHERE id=?",
                    arguments: [entryId]
                ),
                try String.fetchOne(
                    db, sql: "SELECT deleted_at FROM fitness_food_log_entries WHERE id=?",
                    arguments: [entryId]
                )
            )
        }
        XCTAssertEqual(amount, 30, "A refused edit returns to the server's own value")
        XCTAssertNil(removedAt, "An entry the server holds must stay in the diary")
    }

    func testQueuedRemovalSurvivesAChangeThatCrossedItInFlight() async throws {
        let entryId = UUID().uuidString
        let loggedAt = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_food_log_entries
                    (id,food_name,logged_at,nutrition_date,meal,revision,client_updated_at,origin_device_id)
                    VALUES (?,?,?,?,?,3,?,'test-device')
                    """,
                arguments: [entryId, "Porridge", loggedAt, "2026-08-02", "breakfast", loggedAt]
            )
            // The removal this device queued has not been accepted yet.
            try db.execute(
                sql: """
                    INSERT INTO fitness_outbox
                    (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                     base_revision,payload_json,created_at_client)
                    VALUES (?,?,?,'delete',1,3,'{}',?)
                    """,
                arguments: [UUID().uuidString, FitnessEntityType.foodLogEntry.rawValue, entryId, loggedAt]
            )
            try db.execute(
                sql: "UPDATE fitness_food_log_entries SET deleted_at=? WHERE id=?",
                arguments: [loggedAt, entryId]
            )
        }

        // A change the server generated before that removal reached it.
        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [],
            changes: [FitnessSyncChange(
                sequence: 1, entityType: FitnessEntityType.foodLogEntry.rawValue,
                entityId: entryId, revision: 4, operation: "upsert",
                data: [
                    "id": .string(entryId),
                    "food_version_id": .string(UUID().uuidString),
                    "logged_at_utc": .string(loggedAt),
                    "nutrition_date": .string("2026-08-02"),
                    "meal_key": .string("breakfast"),
                    "entered_amount": .double(100),
                    "entered_unit": .string("g"),
                    "canonical_amount": .double(100),
                    "canonical_unit": .string("g"),
                    "updated_at": .string(loggedAt),
                ],
                changedAt: loggedAt
            )],
            redirects: [], notices: [], nextCursor: 1
        )

        try await repository.applySync(response, sentMutationIds: [])

        let stillRemoved = try database.read { db in
            try String.fetchOne(
                db, sql: "SELECT deleted_at FROM fitness_food_log_entries WHERE id=?",
                arguments: [entryId]
            )
        }
        XCTAssertNotNil(stillRemoved, "A queued removal must not be undone by a change that crossed it")
    }

    func testMalformedPersistedFitnessJSONFailsClosedWithoutDroppingRows() async throws {
        let gearId = UUID().uuidString
        let noticeId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql:"""
                    INSERT INTO fitness_gear_items
                    (id,gear_type_key,name,active,revision,payload_json,cached_at)
                    VALUES (?,'shoes','Corrupt gear',1,0,'{',?)
                    """,
                arguments:[gearId,now]
            )
            try db.execute(
                sql:"""
                    INSERT INTO fitness_sync_notices
                    (id,kind,message,created_at,previous_values_json)
                    VALUES (?,'conflict','Corrupt notice',?,'{')
                    """,
                arguments:[noticeId,now]
            )
        }

        let activityRepository = FitnessActivityRepository(database:database)
        do {
            _ = try await activityRepository.cachedGear()
            XCTFail("Malformed cached gear must fail the complete read")
        } catch is DecodingError {
            // Expected: no persisted row is silently omitted.
        }
        do {
            _ = try await repository.notices()
            XCTFail("Malformed notice history must fail the complete read")
        } catch is DecodingError {
            // Expected: conflict history remains visible as a storage failure.
        }

        let retained = try database.read { db in
            (
                try Int.fetchOne(
                    db,sql:"SELECT COUNT(*) FROM fitness_gear_items WHERE id=?",
                    arguments:[gearId]
                ) ?? 0,
                try Int.fetchOne(
                    db,sql:"SELECT COUNT(*) FROM fitness_sync_notices WHERE id=?",
                    arguments:[noticeId]
                ) ?? 0
            )
        }
        XCTAssertEqual(retained.0,1)
        XCTAssertEqual(retained.1,1)
    }

    func testNamedMigrationsAndAtomicFoodOutboxWrite() async throws {
        let applied: [String] = try database.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        XCTAssertEqual(applied, FitnessMigrations.identifiers)

        _ = try await repository.createFood(
            name: "Oats", brand: nil, kcalPer100g: 370, defaultServingGrams: 50
        )

        let counts = try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_foods") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_food_versions") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_outbox") ?? 0
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1, "The record and its one parent mutation commit together")
    }

    func testPendingLocalWorkCountIncludesEveryFitnessQueue() async throws {
        XCTAssertEqual(try database.pendingLocalWorkCount(), 0)

        _ = try await repository.createFood(
            name: "Oats", brand: nil, kcalPer100g: 370, defaultServingGrams: 50
        )
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_activity_context_outbox
                    (mutation_id, activity_id, payload_json, created_at)
                    VALUES (?, ?, '{}', ?)
                    """,
                arguments: [UUID().uuidString, UUID().uuidString, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_planned_meal_outbox
                    (id, owner_identity, meal_plan_id, payload_json, created_at)
                    VALUES (?, 'test:test', ?, '{}', ?)
                    """,
                arguments: [UUID().uuidString, UUID().uuidString, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_fit_imports
                    (id, original_filename, media_type, byte_count, status, created_at, updated_at)
                    VALUES (?, 'pending.fit', 'application/vnd.ant.fit', 128, 'queued', ?, ?)
                    """,
                arguments: [UUID().uuidString, now, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_fit_imports
                    (id, original_filename, media_type, byte_count, status, created_at, updated_at)
                    VALUES (?, 'finished.fit', 'application/vnd.ant.fit', 128, 'complete', ?, ?)
                    """,
                arguments: [UUID().uuidString, now, now]
            )
        }

        XCTAssertEqual(try database.pendingLocalWorkCount(), 4)
    }

    func testCycleWritesUseFitnessOutboxAndKeepSharingCategoriesIndependent() async throws {
        let profile=try await repository.saveCycleSettings(
            existing: nil,cycleLengthDays: 30,
            showPeriodStarts: true,showPredictedPeriod: false,
            showEstimatedOvulation: true,
            sharePeriodStartsWithAdults: true,
            sharePredictedPeriodWithAdults: false,
            shareEstimatedOvulationWithAdults: false
        )
        XCTAssertTrue(profile.isOwner)
        XCTAssertTrue(profile.sharePeriodStartsWithAdults)
        XCTAssertFalse(profile.sharePredictedPeriodWithAdults)
        XCTAssertFalse(profile.shareEstimatedOvulationWithAdults)

        let period=try await repository.recordCyclePeriodStart(
            profile: profile,startedOn: "2026-08-01"
        )
        let updated=try await repository.cycleProfiles().first(where: \.isOwner)
        XCTAssertEqual(updated?.latestPeriodStart,"2026-08-01")
        XCTAssertEqual(updated?.predictedNextPeriod,"2026-08-31")
        XCTAssertEqual(updated?.estimatedOvulation,"2026-08-17")

        let queued=try database.read { db in
            try Row.fetchAll(
                db,sql: "SELECT entity_type,payload_json FROM fitness_outbox ORDER BY created_at_client"
            ).map { ($0["entity_type"] as String,$0["payload_json"] as String) }
        }
        XCTAssertEqual(Set(queued.map(\.0)),Set(["cycle_settings","cycle_period_start"]))
        let settingsJSON=try XCTUnwrap(queued.first(where: { $0.0 == "cycle_settings" })?.1)
        let settingsPayload=try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(settingsJSON.utf8)) as? [String:Any]
        )
        XCTAssertEqual(settingsPayload["share_period_starts_with_adults"] as? Bool,true)
        XCTAssertEqual(settingsPayload["share_predicted_period_with_adults"] as? Bool,false)
        XCTAssertNil(settingsPayload["share_with_adults"])

        // Creating and removing the same start while offline collapses to no
        // period mutation; the server never sees an entity that no longer exists.
        try await repository.deleteCyclePeriodStart(period)
        let afterDelete=try database.read { db in
            (
                try String.fetchAll(db,sql: "SELECT entity_type FROM fitness_outbox"),
                try Int.fetchOne(
                    db,sql: "SELECT COUNT(*) FROM fitness_cycle_period_starts WHERE deleted_at IS NULL"
                ) ?? 0
            )
        }
        XCTAssertEqual(afterDelete.0,["cycle_settings"])
        XCTAssertEqual(afterDelete.1,0)
    }

    func testInvalidOwnedSharedFITIsRetainedForRecovery() async throws {
        let suite = "FitnessFITInboxTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = "family-a:user-a"
        let inbox = directory.appendingPathComponent(FitnessPendingFITInbox.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let missing = inbox.appendingPathComponent("\(UUID().uuidString).fit")
        let payload = SharedFitnessFITPayload(
            id: UUID().uuidString, filePath: missing.path,
            originalFilename: "missing.fit", byteCount: 128,
            createdAt: FitnessDatabase.dateString(Date()), ownerIdentity: identity
        )
        defaults.set(try JSONEncoder().encode([payload]), forKey: FitnessPendingFITInbox.queueKey)
        try FitnessPendingFITInbox.setActiveIdentity(
            identity,
            context: FitnessPendingFITInbox.Context(
                containerURL: directory,
                defaults: defaults
            )
        )

        let adopted = try await FitnessPendingFITInbox.adoptAll(
            identity: identity,
            repository: FitnessActivityRepository(database: database),
            defaults: defaults,
            containerURL: directory
        )

        XCTAssertEqual(adopted, 0)
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                defaults: defaults,
                containerURL: directory
            ),
            1
        )
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                identity: identity,
                defaults: defaults,
                containerURL: directory
            ),
            1
        )
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                identity: "another-owner",
                defaults: defaults,
                containerURL: directory
            ),
            0
        )
        XCTAssertEqual(
            FitnessPendingFITInbox.ownedRecoveryEntries(
                identity: identity,
                defaults: defaults,
                containerURL: directory
            ),
            [payload]
        )
    }

    func testSharedFITStaysWithStampedOwnerAcrossAccountSwitch() async throws {
        let suite = "FitnessFITOwnerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inbox = directory.appendingPathComponent(FitnessPendingFITInbox.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("\(UUID().uuidString).fit")
        try Data([0x0E, 0x10, 0x00, 0x00]).write(to: file)
        let ownerA = "family:user-a"
        let payload = SharedFitnessFITPayload(
            id: UUID().uuidString, filePath: file.path,
            originalFilename: "owner-a.fit", byteCount: 4,
            createdAt: FitnessDatabase.dateString(Date()), ownerIdentity: ownerA
        )
        defaults.set(try JSONEncoder().encode([payload]), forKey: FitnessPendingFITInbox.queueKey)
        let activityRepository = FitnessActivityRepository(database: database)

        try FitnessPendingFITInbox.setActiveIdentity(
            "family:user-b",
            context: FitnessPendingFITInbox.Context(
                containerURL: directory,
                defaults: defaults
            )
        )
        let wrongOwnerAdopted=try await FitnessPendingFITInbox.adoptAll(
            identity: "family:user-b", repository: activityRepository,
            defaults: defaults, containerURL: directory
        )
        XCTAssertEqual(wrongOwnerAdopted,0)
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                defaults: defaults,
                containerURL: directory
            ),
            1
        )
        let retainedEntries = FitnessPendingFITInbox.ownedRecoveryEntries(
            identity: ownerA,
            defaults: defaults,
            containerURL: directory
        )
        XCTAssertEqual(retainedEntries.count, 1)
        let retainedEntry = try XCTUnwrap(retainedEntries.first)
        XCTAssertEqual(retainedEntry.id, payload.id)
        XCTAssertEqual(retainedEntry.ownerIdentity, ownerA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedEntry.filePath))

        try FitnessPendingFITInbox.setActiveIdentity(
            ownerA,
            context: FitnessPendingFITInbox.Context(
                containerURL: directory,
                defaults: defaults
            )
        )
        let correctOwnerAdopted=try await FitnessPendingFITInbox.adoptAll(
            identity: ownerA, repository: activityRepository,
            defaults: defaults, containerURL: directory
        )
        XCTAssertEqual(correctOwnerAdopted,1)
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                defaults: defaults,
                containerURL: directory
            ),
            0
        )
        let pendingImportIds=try await activityRepository.pendingFITImports().map(\.id)
        XCTAssertEqual(pendingImportIds,[payload.id])
    }

    func testPendingFITReconciliationIsReferencedFreshSymlinkSafeAndBounded() async throws {
        let activityRepository = FitnessActivityRepository(database: database)
        let provider = directory.appendingPathComponent("provider.fit")
        try Data([0x0E,0x10,0x00,0x00]).write(to: provider)
        let referenced = try await activityRepository.stageFIT(at: provider)
        let pendingDirectory = directory.appendingPathComponent("PendingFIT",isDirectory: true)
        let referencedURL = try await activityRepository.localFITURL(for: referenced.id)
        let now = Date()
        let old = now.addingTimeInterval(-7_200)
        try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: referencedURL.path)

        let staleFiles = [
            pendingDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).fit"),
            pendingDirectory.appendingPathComponent(".\(UUID().uuidString.lowercased()).staging"),
        ]
        for file in staleFiles {
            try Data("orphan".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: file.path)
        }
        let fresh = pendingDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).fit"
        )
        try Data("fresh".utf8).write(to: fresh)
        let nearMiss = pendingDirectory.appendingPathComponent("manual.fit")
        try Data("manual".utf8).write(to: nearMiss)
        try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: nearMiss.path)
        let symbolicLink = pendingDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).fit"
        )
        try FileManager.default.createSymbolicLink(at: symbolicLink,withDestinationURL: provider)

        let firstPass = try await activityRepository.reconcilePendingFITFiles(
            now: now,minimumAge: 3_600,maximumCandidates: 32,maximumRemovals: 1
        )
        XCTAssertEqual(firstPass,1)
        XCTAssertEqual(
            staleFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))

        let secondPass = try await activityRepository.reconcilePendingFITFiles(
            now: now,minimumAge: 3_600,maximumCandidates: 32,maximumRemovals: 32
        )
        XCTAssertEqual(secondPass,1)
        XCTAssertTrue(staleFiles.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
    }

    func testFITStagingRejectsProviderSymlinkWithoutRemovingItsTarget() async throws {
        let activityRepository = FitnessActivityRepository(database: database)
        let provider = directory.appendingPathComponent("provider.fit")
        let symbolicLink = directory.appendingPathComponent("provider-link.fit")
        try Data([0x0E,0x10,0x00,0x00]).write(to: provider)
        try FileManager.default.createSymbolicLink(at: symbolicLink,withDestinationURL: provider)

        do {
            _ = try await activityRepository.stageFIT(at: symbolicLink)
            XCTFail("Provider symlinks must not enter protected FIT staging")
        } catch FitnessActivityRepositoryError.invalidFIT {
            // Expected.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
    }

    func testGarminDownloadAdoptionMovesValidatedFITWithoutDataRoundTrip() async throws {
        let activityRepository = FitnessActivityRepository(database: database)
        let exportId = UUID().uuidString
        let downloadDirectory = directory.appendingPathComponent(
            "download-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: downloadDirectory,
            withIntermediateDirectories: true
        )
        let source = downloadDirectory.appendingPathComponent("\(exportId).fit")
        try minimalFITData().write(to: source)
        let export = FitnessGarminExport(
            id: exportId,
            workoutVersionId: UUID().uuidString,
            status: "ready",
            fileName: "Workout.fit",
            lastError: nil,
            mappingReport: nil
        )

        let adopted = try await activityRepository.adoptGarminDownload(
            at: source,
            export: export
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.path))
        XCTAssertEqual(try Data(contentsOf: adopted), minimalFITData())
        let cached = try await activityRepository.garminDownloadURL(exportId: exportId)
        XCTAssertEqual(cached, adopted)
    }

    func testGarminAdoptionFailureCleansOwnedTemporaryFileAndPublishesNothing() async throws {
        let activityRepository = FitnessActivityRepository(database: database)
        let exportId = UUID().uuidString
        let downloadDirectory = directory.appendingPathComponent(
            "download-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: downloadDirectory,
            withIntermediateDirectories: true
        )
        let source = downloadDirectory.appendingPathComponent("\(exportId).fit")
        try Data("not a FIT envelope".utf8).write(to: source)
        let export = FitnessGarminExport(
            id: exportId,
            workoutVersionId: UUID().uuidString,
            status: "ready",
            fileName: "Workout.fit",
            lastError: nil,
            mappingReport: nil
        )

        do {
            _ = try await activityRepository.adoptGarminDownload(at: source, export: export)
            XCTFail("A malformed Garmin file must not be published")
        } catch FitnessActivityRepositoryError.invalidFIT {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let cached = try await activityRepository.garminDownloadURL(exportId: exportId)
        XCTAssertNil(cached)
        let published = directory
            .appendingPathComponent("GarminExports", isDirectory: true)
            .appendingPathComponent("\(exportId.lowercased()).fit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
    }

    private func minimalFITData() -> Data {
        // 14-byte FIT header, no data messages, and a two-byte file CRC.
        Data([
            0x0E, 0x20, 0x70, 0x08,
            0x00, 0x00, 0x00, 0x00,
            0x2E, 0x46, 0x49, 0x54,
            0x00, 0x00,
            0x00, 0x00,
        ])
    }

    func testMalformedFitnessZIPValidationRemovesOwnedTransferDirectory() throws {
        let transfer = directory.appendingPathComponent(
            "download-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true)
        let archive = transfer.appendingPathComponent("fitness.zip")
        try Data("not a zip".utf8).write(to: archive)

        XCTAssertThrowsError(
            try FitnessExportService.validateZIPOrRemoveTransfer(at: archive)
        ) { error in
            guard case FitnessExportServiceError.invalidArchive = error else {
                return XCTFail("Expected invalidArchive, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: transfer.path))
    }

    func testFitnessZIPValidationAcceptsDocumentedLeadingSignatures() throws {
        for signature in [
            Data([0x50, 0x4B, 0x03, 0x04]),
            Data([0x50, 0x4B, 0x05, 0x06]),
            Data([0x50, 0x4B, 0x07, 0x08]),
        ] {
            let transfer = directory.appendingPathComponent(
                "download-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: transfer,
                withIntermediateDirectories: true
            )
            let archive = transfer.appendingPathComponent("fitness.zip")
            try signature.write(to: archive)

            XCTAssertNoThrow(
                try FitnessExportService.validateZIPOrRemoveTransfer(at: archive)
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        }
    }

    func testActiveWorkoutAndConcreteSetupSurviveDatabaseReopen() async throws {
        let exercise = try await repository.createExercise(
            name: "Garage press", category: "Strength", loadMode: .total
        )
        let session = try await repository.startWorkout(title: "Offline workout")
        let sessionExercise = try await repository.addExercise(exercise.id, to: session.id)
        XCTAssertFalse(sessionExercise.setupId.isEmpty)

        let storeURL = database.activeStoreURL!
        database.suspend()
        try database.activateForTesting(storeURL: storeURL)
        let reopened = FitnessRepository(database: database, deviceId: "test-device")

        let active = try await reopened.activeWorkout()
        let exercises = try await reopened.workoutExercises(sessionId: session.id)
        XCTAssertEqual(active?.id, session.id)
        XCTAssertEqual(exercises.first?.exercise.setupId, sessionExercise.setupId)
    }

    func testActiveWorkoutClosesAfterOneHourAndAllowsAReplacement() async throws {
        let session = try await repository.startWorkout(title: "Forgotten workout")
        let now = Date()
        let startedAt = now.addingTimeInterval(-61 * 60)
        try database.write { db in
            try db.execute(
                sql: "UPDATE fitness_strength_sessions SET started_at=? WHERE id=?",
                arguments: [FitnessDatabase.dateString(startedAt), session.id]
            )
        }

        let active = try await repository.activeWorkout(now: now)
        XCTAssertNil(active)

        let stored = try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT status,ended_at FROM fitness_strength_sessions WHERE id=?",
                arguments: [session.id]
            )
        }
        let storedStatus: String? = stored?["status"]
        let storedEndedAt = FitnessDatabase.date(stored?["ended_at"])
        XCTAssertEqual(storedStatus, "abandoned")
        XCTAssertNotNil(storedEndedAt)
        XCTAssertEqual(
            storedEndedAt!.timeIntervalSince1970,
            startedAt.addingTimeInterval(60 * 60).timeIntervalSince1970,
            accuracy: 0.001
        )
        let payloads = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT payload_json FROM fitness_outbox WHERE entity_id=? ORDER BY created_at_client",
                arguments: [session.id]
            )
        }
        XCTAssertEqual(payloads.count, 2)
        XCTAssertTrue(payloads.last?.contains("\"status\":\"aborted\"") == true)

        let replacement = try await repository.startWorkout(title: "Fresh workout")
        let replacementActive = try await repository.activeWorkout()
        XCTAssertEqual(replacementActive?.id, replacement.id)
    }

    func testServerCreatedGoalFoodVersionExerciseAndSetupMaterialiseIntoEmptyStore() async throws {
        let goalId = UUID().uuidString
        let foodId = UUID().uuidString
        let versionId = UUID().uuidString
        let exerciseId = UUID().uuidString
        let setupId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())

        let changes = [
            FitnessSyncChange(
                sequence: 1, entityType: "goal", entityId: goalId, revision: 1,
                operation: "upsert",
                data: [
                    "id": .string(goalId), "name": .string("Build strength"),
                    "metric_key": .string("strength.e1rm"), "goal_type": .string("fitness"),
                    "starts_on": .string("2026-08-02"), "unit_key": .string("kg"),
                    "target_value": .double(100), "updated_at": .string(now),
                ],
                changedAt: now
            ),
            FitnessSyncChange(
                sequence: 2, entityType: "food", entityId: foodId, revision: 1,
                operation: "upsert",
                data: [
                    "id": .string(foodId), "name": .string("Server oats"),
                    "active": .bool(true), "favourite": .bool(false),
                    "current_version": .object([
                        "id": .string(versionId), "reference_amount": .double(100),
                        "reference_unit": .string("g"), "calories_kcal": .double(370),
                        "created_at": .string(now),
                    ]),
                    "versions": .array([.object([
                        "id": .string(versionId), "reference_amount": .double(100),
                        "reference_unit": .string("g"), "calories_kcal": .double(370),
                        "created_at": .string(now),
                    ])]),
                    "updated_at": .string(now),
                ],
                changedAt: now
            ),
            FitnessSyncChange(
                sequence: 3, entityType: "exercise", entityId: exerciseId, revision: 1,
                operation: "upsert",
                data: [
                    "id": .string(exerciseId), "seed_key": .string("back_squat"),
                    "name": .string("Back Squat"), "movement_pattern_key": .string("squat"),
                    "load_entry_mode": .string("total_external"), "active": .bool(true),
                    "setups": .array([.object([
                        "id": .string(setupId), "exercise_id": .string(exerciseId),
                        "name": .string("Default"), "load_entry_mode": .string("total_external"),
                        "bar_weight_kg": .double(20), "is_default": .bool(true),
                        "active": .bool(true), "revision": .int(1),
                    ])]),
                    "updated_at": .string(now),
                ],
                changedAt: now
            ),
        ]
        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [], changes: changes, redirects: [], notices: [], nextCursor: 3
        )

        try await repository.applySync(response, sentMutationIds: [])

        let goalIds = try await repository.goals().map(\.id)
        let materialisedVersionId = try await repository.foods().first?.versionId
        let materialisedExerciseId = try await repository.exercises().first?.id
        let materialisedSetupId = try await repository.setups(for: exerciseId).first?.id
        XCTAssertEqual(goalIds, [goalId])
        XCTAssertEqual(materialisedVersionId, versionId)
        XCTAssertEqual(materialisedExerciseId, exerciseId)
        XCTAssertEqual(materialisedSetupId, setupId)
    }

    func testPlannedSessionNestedIdentifiersSurviveOutboxServerRoundTrip() async throws {
        let exercise = try await repository.createExercise(
            name: "Front squat", category: "Strength", loadMode: .total
        )
        let plan = try await repository.createPlannedSession(
            title: "Tuesday strength", plannedFor: Date(), exerciseIds: [exercise.id],
            workingSets: 2, targetReps: 5
        )
        let mutations = try await repository.pendingMutations()
        let mutation = try XCTUnwrap(
            mutations.first { $0.entityType == FitnessEntityType.plannedSession.rawValue }
        )
        guard let exerciseItems = mutation.payload["exercise_items"],
              case .array(let itemValues) = exerciseItems,
              let firstItem = itemValues.first,
              case .object(let item) = firstItem,
              let plannedSets = item["planned_sets"],
              case .array(let setValues) = plannedSets else {
            return XCTFail("The planned-session mutation must contain relational children")
        }
        let payloadExerciseId = try XCTUnwrap(item["id"]?.stringValue)
        let payloadSetupId = try XCTUnwrap(item["exercise_setup_id"]?.stringValue)
        let payloadSetIds = setValues.compactMap { value -> String? in
            guard case .object(let set) = value else { return nil }
            return set["id"]?.stringValue
        }
        XCTAssertEqual(payloadSetIds.count, 2)

        let localIds = try database.read { db in
            (
                try String.fetchOne(
                    db,
                    sql: "SELECT exercise_setup_id FROM fitness_planned_session_exercises WHERE id = ?",
                    arguments: [payloadExerciseId]
                ),
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM fitness_planned_sets WHERE planned_exercise_id = ? ORDER BY position",
                    arguments: [payloadExerciseId]
                )
            )
        }
        XCTAssertEqual(localIds.0, payloadSetupId)
        XCTAssertEqual(localIds.1, payloadSetIds)

        try database.write { db in
            try db.execute(
                sql: "DELETE FROM fitness_planned_sets WHERE planned_exercise_id = ?",
                arguments: [payloadExerciseId]
            )
            try db.execute(
                sql: "DELETE FROM fitness_planned_session_exercises WHERE planned_session_id = ?",
                arguments: [plan.id]
            )
            try db.execute(sql: "DELETE FROM fitness_planned_sessions WHERE id = ?", arguments: [plan.id])
        }
        let now = FitnessDatabase.dateString(Date())
        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [],
            changes: [FitnessSyncChange(
                sequence: 1, entityType: mutation.entityType, entityId: mutation.entityId,
                revision: 1, operation: "upsert", data: mutation.payload, changedAt: now
            )],
            redirects: [], notices: [], nextCursor: 1
        )
        try await repository.applySync(response, sentMutationIds: [])

        let restored = try database.read { db in
            (
                try String.fetchOne(
                    db,
                    sql: "SELECT exercise_setup_id FROM fitness_planned_session_exercises WHERE id = ?",
                    arguments: [payloadExerciseId]
                ),
                try String.fetchAll(
                    db,
                    sql: "SELECT id FROM fitness_planned_sets WHERE planned_exercise_id = ? ORDER BY position",
                    arguments: [payloadExerciseId]
                )
            )
        }
        XCTAssertEqual(restored.0, payloadSetupId)
        XCTAssertEqual(restored.1, payloadSetIds)
    }

    func testDeletingSyncedPlannedSessionCreatesOneTombstoneAndHidesItsLocalGraph() async throws {
        let exercise = try await repository.createExercise(
            name: "Goblet squat", category: "Strength", loadMode: .total
        )
        let plan = try await repository.createPlannedSession(
            title: "Friday strength", plannedFor: Date(), exerciseIds: [exercise.id],
            workingSets: 2, targetReps: 8
        )
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                arguments: [FitnessEntityType.plannedSession.rawValue, plan.id]
            )
            try db.execute(
                sql: "UPDATE fitness_planned_sessions SET revision=4 WHERE id=?",
                arguments: [plan.id]
            )
        }

        try await repository.deletePlannedSession(plan.id)

        let remainingPlans = try await repository.plannedSessions()
        XCTAssertFalse(remainingPlans.contains { $0.id == plan.id })
        let mutations = try await repository.pendingMutations()
        let deletion = try XCTUnwrap(
            mutations.first {
                $0.entityType == FitnessEntityType.plannedSession.rawValue
                    && $0.entityId == plan.id
            }
        )
        XCTAssertEqual(deletion.operation, FitnessMutationOperation.delete.rawValue)
        XCTAssertEqual(deletion.baseRevision, 4)
        let deletedCounts = try database.read { db in
            (
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM fitness_planned_sessions WHERE id=? AND deleted_at IS NOT NULL",
                    arguments: [plan.id]
                ) ?? 0,
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM fitness_planned_session_exercises WHERE planned_session_id=? AND deleted_at IS NOT NULL",
                    arguments: [plan.id]
                ) ?? 0
            )
        }
        XCTAssertEqual(deletedCounts.0, 1)
        XCTAssertEqual(deletedCounts.1, 1)
    }

    func testQuickRunKeepsOptionalPaceInLocalPlanAndOfflineMutation() async throws {
        let start=Date(timeIntervalSince1970:1_786_345_200)
        let plan=try await repository.createQuickPlannedSession(
            sportKey:"running",title:"Run",scheduledStart:start,
            expectedDurationSeconds:1_575,expectedDistanceMetres:5_000,
            expectedPaceSecondsPerKilometre:315,status:"accepted",movable:false,
            programmeId:nil,primaryGoalId:nil
        )
        XCTAssertEqual(plan.title,"Run")
        XCTAssertEqual(plan.expectedPaceSecondsPerKilometre,315)
        XCTAssertFalse(plan.movable)

        let plans=try await repository.plannedSessions()
        let reloaded=try XCTUnwrap(plans.first { $0.id == plan.id })
        XCTAssertEqual(reloaded.expectedDistanceMetres,5_000)
        XCTAssertEqual(reloaded.expectedPaceSecondsPerKilometre,315)
        let mutations=try await repository.pendingMutations()
        let mutation=try XCTUnwrap(
            mutations.first {
                $0.entityType == FitnessEntityType.plannedSession.rawValue && $0.entityId == plan.id
            }
        )
        XCTAssertEqual(mutation.payload["expected_pace_s_per_km"]?.doubleValue,315)
        XCTAssertEqual(mutation.payload["status"]?.stringValue,"accepted")
    }

    func testWorkoutDefinitionAndTrainingProgrammeMaterialiseTypedRelations() async throws {
        let goalId = UUID().uuidString
        let definitionId = UUID().uuidString
        let versionId = UUID().uuidString
        let exerciseId = UUID().uuidString
        let itemId = UUID().uuidString
        let setId = UUID().uuidString
        let programmeId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())
        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [], changes: [
                FitnessSyncChange(
                    sequence: 1, entityType: "workout_definition", entityId: definitionId,
                    revision: 2, operation: "upsert", data: [
                        "id": .string(definitionId), "sport_key": .string("strength"),
                        "name": .string("Heavy day"), "active": .bool(true),
                        "current_version": .object([
                            "id": .string(versionId), "version_number": .int(1),
                            "title": .string("Heavy day v1"), "version_source": .string("user"),
                            "structured_summary": .object(["focus": .string("squat")]),
                            "exercise_items": .array([.object([
                                "id": .string(itemId), "exercise_id": .string(exerciseId),
                                "sequence": .int(0), "substitution_exercise_ids": .array([]),
                                "planned_sets": .array([.object([
                                    "id": .string(setId), "sequence": .int(0),
                                    "training_role": .string("working"),
                                    "structure_type": .string("straight"),
                                    "component_count": .int(1), "reps_min": .int(5),
                                    "reps_max": .int(5), "is_amrap": .bool(false),
                                ])]),
                            ])]),
                        ]),
                        "updated_at": .string(now),
                    ], changedAt: now
                ),
                FitnessSyncChange(
                    sequence: 2, entityType: "training_programme", entityId: programmeId,
                    revision: 1, operation: "upsert", data: [
                        "id": .string(programmeId), "name": .string("Autumn strength"),
                        "starts_on": .string("2026-08-03"), "status": .string("active"),
                        "programme_source": .string("user"),
                        "goal_links": .array([.object([
                            "goal_id": .string(goalId), "role": .string("primary"),
                        ])]),
                        "updated_at": .string(now),
                    ], changedAt: now
                ),
            ], redirects: [], notices: [], nextCursor: 2
        )

        try await repository.applySync(response, sentMutationIds: [])

        let materialised = try database.read { db in
            (
                try String.fetchOne(
                    db, sql: "SELECT current_version_id FROM fitness_workout_definitions WHERE id = ?",
                    arguments: [definitionId]
                ),
                try String.fetchOne(
                    db, sql: "SELECT id FROM fitness_workout_version_exercises WHERE workout_version_id = ?",
                    arguments: [versionId]
                ),
                try String.fetchOne(
                    db, sql: "SELECT id FROM fitness_workout_version_sets WHERE workout_version_exercise_id = ?",
                    arguments: [itemId]
                ),
                try String.fetchOne(
                    db, sql: "SELECT goal_id FROM fitness_training_programme_goal_links WHERE training_programme_id = ?",
                    arguments: [programmeId]
                )
            )
        }
        XCTAssertEqual(materialised.0, versionId)
        XCTAssertEqual(materialised.1, itemId)
        XCTAssertEqual(materialised.2, setId)
        XCTAssertEqual(materialised.3, goalId)
    }

    func testFullSnapshotAtomicallyReplacesCacheAndPreservesUnackedWork() async throws {
        let oldGoalId=UUID().uuidString
        let newGoalId=UUID().uuidString
        let now=FitnessDatabase.dateString(Date())
        let incremental=FitnessSyncResponse(
            status: "ok",currentSyncProtocolVersion: 1,currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1,accepted: [],ackedMutationIds: [],
            rejectedMutations: [],changes: [FitnessSyncChange(
                sequence: 4,entityType: "goal",entityId: oldGoalId,revision: 1,
                operation: "upsert",data: [
                    "id": .string(oldGoalId),"name": .string("Stale goal"),
                    "metric_key": .string("body.weight_kg"),"target_value": .double(80),
                    "updated_at": .string(now),
                ],changedAt: now
            )],redirects: [],notices: [],nextCursor: 4
        )
        try await repository.applySync(incremental,sentMutationIds: [])

        let pendingFood=try await repository.createFood(
            name: "Offline oats",brand: nil,kcalPer100g: 370,defaultServingGrams: 50
        )
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_pending_files
                    (asset_id,relative_path,media_type,byte_count,state,created_at)
                    VALUES ('pending-file','pending/photo.jpg','image/jpeg',10,'pending',?)
                    """,
                arguments: [now]
            )
        }

        let response=FitnessSyncResponse(
            status: "full_snapshot_required",currentSyncProtocolVersion: 1,currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1,accepted: [],ackedMutationIds: [],
            rejectedMutations: [],changes: [],redirects: [],notices: [],nextCursor: 40,
            snapshotUrl: "/api/fitness/sync/snapshot",message: "Refresh required"
        )
        let snapshot=FitnessSnapshotResponse(
            status: "ok",currentSyncProtocolVersion: 1,currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1,generatedAt: now,
            entities: [FitnessSnapshotEntity(
                entityType: "goal",entityId: newGoalId,revision: 2,data: [
                    "id": .string(newGoalId),"name": .string("Current goal"),
                    "metric_key": .string("running.distance_m"),
                    "target_value": .double(10_000),"updated_at": .string(now),
                ]
            )],
            redirects: [FitnessSyncRedirect(
                entityType: "goal",sourceId: oldGoalId,targetId: newGoalId
            )],nextCursor: 50
        )

        try await repository.applySnapshot(snapshot,syncResponse: response,sentMutationIds: [])

        let goalIds=try await repository.goals().map(\.id)
        let foodIds=try await repository.foods().map(\.id)
        XCTAssertEqual(goalIds,[newGoalId])
        XCTAssertEqual(foodIds,[pendingFood.id])
        let preserved=try database.read { db in
            (
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_outbox") ?? 0,
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_pending_files") ?? 0,
                try String.fetchOne(
                    db,sql: "SELECT target_id FROM fitness_redirects WHERE entity_type='goal' AND source_id=?",
                    arguments: [oldGoalId]
                )
            )
        }
        XCTAssertEqual(preserved.0,1)
        XCTAssertEqual(preserved.1,1)
        XCTAssertEqual(preserved.2,newGoalId)
        let cursor=try await repository.syncCursor()
        XCTAssertEqual(cursor,50)
    }

    func testStoreLeaseRejectsBlockedOwnerACommitAfterOwnerBSwitch() async throws {
        let leaseA = try database.lease(for: "test:test")
        let gate = FitnessRepositoryTestGate()
        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [], changes: [FitnessSyncChange(
                sequence: 1, entityType: "goal", entityId: UUID().uuidString,
                revision: 1, operation: "upsert",
                data: [
                    "id": .string(UUID().uuidString), "name": .string("Owner A goal"),
                    "metric_key": .string("running.distance_m"),
                    "target_value": .double(5_000),
                    "updated_at": .string(FitnessDatabase.dateString(Date())),
                ],
                changedAt: FitnessDatabase.dateString(Date())
            )], redirects: [], notices: [], nextCursor: 1
        )
        let blockedCommit = Task {
            try await database.withLease(leaseA) {
                await gate.wait()
                try await repository.applySync(response, sentMutationIds: [])
            }
        }
        await gate.waitUntilBlocked()

        database.suspend()
        try database.activateForTesting(
            identity: "family-b:user-b",
            storeURL: directory.appendingPathComponent("owner-b/fitness.sqlite")
        )
        await gate.open()

        do {
            try await blockedCommit.value
            XCTFail("The previous owner's response must not commit into the replacement store")
        } catch let error as FitnessDatabaseError {
            guard case .staleLease = error else {
                return XCTFail("Expected a stale store lease, received \(error)")
            }
        }
        let replacementGoals = try await repository.goals()
        let replacementCursor = try await repository.syncCursor()
        XCTAssertTrue(replacementGoals.isEmpty)
        XCTAssertEqual(replacementCursor, 0)
    }

    func testMixedAcceptedRejectedFullSnapshotJournalsFailureWithoutReplay() async throws {
        let rejectedFood = try await repository.createFood(
            name: "Merged oats", brand: nil, kcalPer100g: 370, defaultServingGrams: 50
        )
        let acceptedFood = try await repository.createFood(
            name: "Accepted oats", brand: nil, kcalPer100g: 365, defaultServingGrams: 50
        )
        let queued = try await repository.pendingMutations()
        let rejectedMutation = try XCTUnwrap(queued.first { $0.entityId == rejectedFood.id })
        let acceptedMutation = try XCTUnwrap(queued.first { $0.entityId == acceptedFood.id })
        let now = FitnessDatabase.dateString(Date())
        let canonicalId = UUID().uuidString
        let noticeId = UUID().uuidString
        let response = FitnessSyncResponse(
            status: "full_snapshot_required", currentSyncProtocolVersion: 1,
            currentClientSchemaVersion: 1, minimumSupportedClientSchemaVersion: 1,
            accepted: [FitnessSyncAccepted(
                mutationId: acceptedMutation.mutationId,
                entityId: acceptedMutation.entityId,
                revision: 2
            )],
            ackedMutationIds: [acceptedMutation.mutationId, rejectedMutation.mutationId],
            rejectedMutations: [FitnessSyncRejected(
                mutationId: rejectedMutation.mutationId,
                entityId: rejectedMutation.entityId,
                code: "canonical_identity_changed", message: nil, retryable: nil,
                targetId: canonicalId,
                targetSummary: ["id": .string(canonicalId), "name": .string("Canonical oats")],
                noticeId: noticeId
            )],
            changes: [], redirects: [], notices: [], nextCursor: 8,
            snapshotUrl: "/api/fitness/sync/snapshot", message: "Refresh required"
        )
        let serverGoalId = UUID().uuidString
        let snapshot = FitnessSnapshotResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, generatedAt: now,
            entities: [FitnessSnapshotEntity(
                entityType: "goal", entityId: serverGoalId, revision: 1,
                data: [
                    "id": .string(serverGoalId), "name": .string("Current goal"),
                    "metric_key": .string("running.distance_m"),
                    "target_value": .double(10_000), "updated_at": .string(now),
                ]
            )], redirects: [], nextCursor: 9
        )

        try await repository.applySnapshot(
            snapshot,
            syncResponse: response,
            sentMutationIds: Set(queued.map(\.mutationId))
        )

        let pendingAfterSnapshot = try await repository.pendingMutations()
        let foodsAfterSnapshot = try await repository.foods()
        let goalsAfterSnapshot = try await repository.goals()
        let cursorAfterSnapshot = try await repository.syncCursor()
        XCTAssertTrue(pendingAfterSnapshot.isEmpty)
        XCTAssertTrue(foodsAfterSnapshot.isEmpty)
        XCTAssertEqual(goalsAfterSnapshot.map(\.id), [serverGoalId])
        XCTAssertEqual(cursorAfterSnapshot, 9)
        let rejections = try await repository.syncRejections()
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(rejections.first?.mutation.mutationId, rejectedMutation.mutationId)
        XCTAssertEqual(rejections.first?.code, "canonical_identity_changed")
        XCTAssertEqual(rejections.first?.disposition, .permanent)
        XCTAssertEqual(rejections.first?.attemptCount, 1)
        XCTAssertEqual(rejections.first?.targetEntityId, canonicalId)
        XCTAssertEqual(rejections.first?.targetSummary?["name"], .string("Canonical oats"))
        let noticesBeforeDismissal = try await repository.notices()
        let pendingBeforeDismissal = try database.pendingLocalWorkCount()
        XCTAssertEqual(noticesBeforeDismissal.first?.id, noticeId)
        XCTAssertEqual(pendingBeforeDismissal, 1)
        try await repository.dismissNotice(noticeId)
        let rejectionsAfterDismissal = try await repository.syncRejections()
        let pendingAfterDismissal = try database.pendingLocalWorkCount()
        XCTAssertTrue(rejectionsAfterDismissal.isEmpty)
        XCTAssertEqual(pendingAfterDismissal, 0)
    }

    func testRetryableRejectionRequiresExplicitRequeue() async throws {
        let food = try await repository.createFood(
            name: "Deferred oats", brand: nil, kcalPer100g: 360, defaultServingGrams: 45
        )
        let initialPending = try await repository.pendingMutations()
        let mutation = try XCTUnwrap(initialPending.first { $0.entityId == food.id })
        let response = FitnessSyncResponse(
            status: "ok", currentSyncProtocolVersion: 1, currentClientSchemaVersion: 1,
            minimumSupportedClientSchemaVersion: 1, accepted: [], ackedMutationIds: [],
            rejectedMutations: [FitnessSyncRejected(
                mutationId: mutation.mutationId, entityId: mutation.entityId,
                code: "dependency_pending", message: "The food library is still updating.",
                retryable: true, targetId: nil, targetSummary: nil, noticeId: nil
            )], changes: [], redirects: [], notices: [], nextCursor: 1
        )

        try await repository.applySync(response, sentMutationIds: [mutation.mutationId])

        let pendingAfterRejection = try await repository.pendingMutations()
        XCTAssertTrue(
            pendingAfterRejection.isEmpty,
            "A rejected mutation must not be silently included in the next background sync"
        )
        let retryableRejections = try await repository.syncRejections()
        XCTAssertEqual(retryableRejections.first?.disposition, .retryable)
        let noticesAfterRejection = try await repository.notices()
        let retryNotice = try XCTUnwrap(noticesAfterRejection.first)
        XCTAssertEqual(retryNotice.rejectedMutationId, mutation.mutationId)
        XCTAssertEqual(retryNotice.rejectionDisposition, .retryable)

        let retriedMutation = try await repository.retryRejectedMutation(mutation.mutationId)
        let retryMutationId = try XCTUnwrap(retriedMutation)

        XCTAssertNotEqual(retryMutationId, mutation.mutationId)
        let pendingAfterRetry = try await repository.pendingMutations()
        let rejectionsAfterRetry = try await repository.syncRejections()
        let noticesAfterRetry = try await repository.notices()
        XCTAssertEqual(pendingAfterRetry.map(\.mutationId), [retryMutationId])
        XCTAssertTrue(rejectionsAfterRetry.isEmpty)
        XCTAssertTrue(noticesAfterRetry.isEmpty)
        let history = try await repository.syncRejections(includeResolved: true)
        XCTAssertEqual(history.first?.mutation.mutationId, mutation.mutationId)
        XCTAssertEqual(history.first?.attemptCount, 1)
        let attemptCount = try database.read { db in
            try Int.fetchOne(
                db, sql: "SELECT attempt_count FROM fitness_outbox WHERE mutation_id=?",
                arguments: [retryMutationId]
            )
        }
        XCTAssertEqual(attemptCount, 0)
    }

    @MainActor
    func testNextActionDismissalIsBoundToEncryptedActiveIdentityStore() throws {
        let firstIdentity=try XCTUnwrap(database.activeIdentity)
        let source="body_issue:\(UUID().uuidString)"
        let target=UUID().uuidString
        let action=FitnessNextAction(
            title:"Review issue",body:"Check the recorded issue before training.",urgency:.attention,
            evidence:[],action:.init(kind:"open_body_issue",target:target,label:"Review"),
            secondaryAction:nil,expiresAt:"2099-01-01T00:00:00Z",
            source:source
        )
        let firstStore=FitnessNextActionDismissalStore(database:database)
        try firstStore.dismiss(action,identity:firstIdentity)
        XCTAssertTrue(try firstStore.isDismissed(action,identity:firstIdentity))
        let changedAction=FitnessNextAction(
            title:"Pause and review issue",body:"The issue is now more severe.",urgency:.urgent,
            evidence:[.init(id:target,kind:"body_issue",label:"Severity changed",summary:"Now 7/10")],
            action:.init(kind:"open_body_issue",target:target,label:"Review now"),
            secondaryAction:.init(kind:"open_coach",target:target,label:"Ask Coach"),
            expiresAt:action.expiresAt,source:source
        )
        XCTAssertFalse(
            try firstStore.isDismissed(changedAction,identity:firstIdentity),
            "Changed action content with the same source and expiry must remain visible"
        )

        database.suspend()
        try database.activateForTesting(
            identity:"family-a:user-b",storeURL:directory.appendingPathComponent("other/fitness.sqlite")
        )
        let secondStore=FitnessNextActionDismissalStore(database:database)
        XCTAssertFalse(try secondStore.isDismissed(action,identity:"family-a:user-b"))
        XCTAssertThrowsError(try firstStore.dismiss(action,identity:firstIdentity)) { error in
            XCTAssertEqual(
                error as? FitnessNextActionDismissalStoreError,
                .identityChanged
            )
        }
        XCTAssertThrowsError(try firstStore.isDismissed(action,identity:firstIdentity)) { error in
            XCTAssertEqual(
                error as? FitnessNextActionDismissalStoreError,
                .identityChanged
            )
        }
    }
}

private actor FitnessRepositoryTestGate {
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isBlocked = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        while !isBlocked { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FitnessLeaseProbeViewModel: FitnessViewModelBase {
    private let repository: FitnessRepository

    init(repository: FitnessRepository) {
        self.repository = repository
    }

    func createFoodAfterResponse(_ gate: FitnessRepositoryTestGate) async {
        await run {
            await gate.wait()
            _ = try await self.repository.createFood(
                name: "Late owner A food", brand: nil,
                kcalPer100g: 300, defaultServingGrams: 50
            )
        }
    }
}

final class FitnessViewModelLeaseTests: XCTestCase {
    @MainActor
    func testDirectViewModelResponseCannotWriteReplacementOwnerStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitnessVMLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            FitnessDatabase.shared.suspend()
            try? FileManager.default.removeItem(at: root)
        }
        try FitnessDatabase.shared.activateForTesting(
            identity: "family-a:user-a",storeURL: root.appendingPathComponent("a/fitness.sqlite"),
            requiresLease: true
        )
        let repository = FitnessRepository(database: .shared, deviceId: "lease-test")
        let viewModel = FitnessLeaseProbeViewModel(repository: repository)
        let gate = FitnessRepositoryTestGate()
        let request = Task { await viewModel.createFoodAfterResponse(gate) }
        await gate.waitUntilBlocked()

        FitnessDatabase.shared.suspend()
        try FitnessDatabase.shared.activateForTesting(
            identity: "family-b:user-b",storeURL: root.appendingPathComponent("b/fitness.sqlite"),
            requiresLease: true
        )
        await gate.open()
        await request.value

        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertThrowsError(try FitnessDatabase.shared.read { _ in () }) { error in
            guard let databaseError=error as? FitnessDatabaseError,
                  case .leaseRequired=databaseError else {
                return XCTFail("Production-style stores must reject unbound access")
            }
        }
        let leaseB = try FitnessDatabase.shared.lease(for: "family-b:user-b")
        let ownerBFoods = try await FitnessDatabase.shared.withLease(leaseB) {
            try await repository.foods()
        }
        XCTAssertTrue(ownerBFoods.isEmpty)
    }
}

final class FitnessCalculationsTests: XCTestCase {
    func testNutritionDayChangesAtFourAM() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T03:59:00Z"))
        let after = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T04:00:00Z"))
        XCTAssertEqual(FitnessCalculations.nutritionDate(for: before, calendar: calendar), "2026-08-01")
        XCTAssertEqual(FitnessCalculations.nutritionDate(for: after, calendar: calendar), "2026-08-02")
    }

    func testPartialPositiveWorkCountsButSkippedAndUnknownEffortDoNot() {
        let group = FitnessSetGroup(
            id: UUID().uuidString, sessionExerciseId: UUID().uuidString,
            role: .working, structure: .straight, isAMRAP: false,
            failureState: .unknown, status: .partial, position: 0, revision: 0, updatedAt: Date()
        )
        let partial = FitnessSetComponent(
            id: UUID().uuidString, groupId: group.id, status: .partial,
            loadKg: 80, reps: 5, durationSeconds: nil, distanceMetres: nil,
            rir: nil, rpe: nil, completedAt: Date(), position: 0, revision: 0, updatedAt: Date()
        )
        let skipped = FitnessSetComponent(
            id: UUID().uuidString, groupId: group.id, status: .skipped,
            loadKg: 100, reps: 10, durationSeconds: nil, distanceMetres: nil,
            rir: 0, rpe: 10, completedAt: nil, position: 1, revision: 0, updatedAt: Date()
        )
        XCTAssertEqual(FitnessCalculations.volume([partial, skipped]), 400)
        XCTAssertFalse(FitnessCalculations.isHardSet(group: group, components: [partial, skipped]))
        XCTAssertNil(FitnessCalculations.eligibleEpley(group: group, components: [partial, skipped]))
        var zeroPartial = partial
        zeroPartial.reps = 0
        XCTAssertFalse(FitnessCalculations.isPerformed(zeroPartial))
    }

    func testEligibleEpleyUsesTenRepCeilingAndStraightHardWork() {
        var group = FitnessSetGroup(
            id: UUID().uuidString, sessionExerciseId: UUID().uuidString,
            role: .working, structure: .straight, isAMRAP: false,
            failureState: .none, status: .completed, position: 0, revision: 0, updatedAt: Date()
        )
        let component = FitnessSetComponent(
            id: UUID().uuidString, groupId: group.id, status: .completed,
            loadKg: 100, reps: 8, durationSeconds: nil, distanceMetres: nil,
            rir: 2, rpe: nil, completedAt: Date(), position: 0, revision: 0, updatedAt: Date()
        )
        let estimate = FitnessCalculations.eligibleEpley(group: group, components: [component])
        XCTAssertEqual(try XCTUnwrap(estimate), 133.3333333333, accuracy: 0.001)
        var tooMany = component
        tooMany.reps = 9 // 9 observed + 2 RIR exceeds the ten effective-rep ceiling.
        XCTAssertNil(FitnessCalculations.eligibleEpley(group: group, components: [tooMany]))
        group.role = .backoff
        XCTAssertNotNil(FitnessCalculations.eligibleEpley(group: group, components: [component]))
        group.structure = .drop
        XCTAssertNil(FitnessCalculations.eligibleEpley(group: group, components: [component]))
    }
}
