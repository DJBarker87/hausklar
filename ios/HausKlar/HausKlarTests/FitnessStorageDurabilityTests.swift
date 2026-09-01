import Darwin
import GRDB
import XCTest

@testable import HausKlar

private final class PausingFITCopyFileManager: FileManager {
    private let condition = NSCondition()
    private var pausedSources: Set<String>
    private var startedSources = Set<String>()
    private var isReleased = false

    init(pausedSources: Set<String>) {
        self.pausedSources = pausedSources
        super.init()
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        let sourceName = sourceURL.lastPathComponent
        if pausedSources.contains(sourceName), destinationURL.lastPathComponent == "asset.fit" {
            condition.lock()
            startedSources.insert(sourceName)
            condition.broadcast()
            while !isReleased { condition.wait() }
            condition.unlock()
        }
        try super.copyItem(at: sourceURL, to: destinationURL)
    }

    func waitUntilAllCopiesStart(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while startedSources != pausedSources {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseCopies() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class FITEnqueueResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: Result<String, Error>] = [:]

    func store(_ result: Result<String, Error>, for owner: String) {
        lock.lock()
        results[owner] = result
        lock.unlock()
    }

    func result(for owner: String) -> Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return results[owner]
    }
}

private final class FITProducerBoundaryGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var didCapture = false
    private var isReleased = false

    func pause() {
        condition.lock()
        didCapture = true
        condition.broadcast()
        while !isReleased { condition.wait() }
        condition.unlock()
    }

    func waitUntilCaptured(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !didCapture {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

final class FitnessStorageDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FitnessStorageDurability-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testIdentityDirectoryHashPreventsRetiredPathCollisions() {
        let first = "family:a/b"
        let second = "family:a_b"
        XCTAssertEqual(
            FitnessDatabase.legacyIdentityDirectoryName(first),
            FitnessDatabase.legacyIdentityDirectoryName(second)
        )
        XCTAssertNotEqual(
            FitnessDatabase.identityDirectoryName(first),
            FitnessDatabase.identityDirectoryName(second)
        )
        XCTAssertEqual(FitnessDatabase.identityDirectoryName(first).count, 70)
        XCTAssertFalse(FitnessDatabase.identityDirectoryName(first).contains(first))
    }

    func testLegacyStoreMovesOnlyWithExactOwnerProof() throws {
        let identity = "family-a:user/a"
        let legacy = root.appendingPathComponent(
            FitnessDatabase.legacyIdentityDirectoryName(identity), isDirectory: true
        )
        let legacyStore = legacy.appendingPathComponent("fitness.sqlite")
        let seed = FitnessDatabase()
        try seed.activateForTesting(identity: identity, storeURL: legacyStore)
        try seed.write { db in
            try db.execute(
                sql: "INSERT INTO fitness_metadata(key,value) VALUES ('legacy_test','kept')"
            )
        }
        seed.suspend()

        let database = FitnessDatabase(rootDirectory: root)
        XCTAssertThrowsError(try database.activate(identity: identity, legacyOwnerProof: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStore.path))

        try database.activate(identity: identity, legacyOwnerProof: identity)
        defer { database.suspend() }
        let expectedDirectory = root.appendingPathComponent(
            FitnessDatabase.identityDirectoryName(identity), isDirectory: true
        )
        XCTAssertEqual(database.activeStoreURL?.deletingLastPathComponent(), expectedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(
            try database.readCurrent(identity: identity) { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT value FROM fitness_metadata WHERE key='legacy_test'"
                )
            }, "kept")
    }

    func testFailedMigrationPublishesVerifiedOwnerBoundBackupAndCanRestoreIt() throws {
        let identity = "family-a:user-a"
        let store = root.appendingPathComponent("owner-a/fitness.sqlite")
        let seed = FitnessDatabase(
            migrationIdentifiers: ["001"],
            migratorFactory: { Self.testMigrator(through: 1) }
        )
        try seed.activateForTesting(identity: identity, storeURL: store)
        try seed.write { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
            try db.execute(sql: "INSERT INTO durable_values(id,value) VALUES (1,'from-wal')")
        }
        seed.suspend()

        let failing = FitnessDatabase(
            migrationIdentifiers: ["001", "002"],
            migratorFactory: { Self.testMigrator(through: 2, failingAt: 2) }
        )
        var reportedBackup: URL?
        XCTAssertThrowsError(
            try failing.activateForTesting(identity: identity, storeURL: store)
        ) { error in
            guard case FitnessDatabaseError.migrationFailed(_, let backup, _) = error else {
                return XCTFail("Expected a preserved migration failure, received \(error)")
            }
            reportedBackup = backup
        }
        let backups = try failing.verifiedRecoveryBackups(identity: identity, storeURL: store)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(backups.first?.url, reportedBackup)
        XCTAssertEqual(backups.first?.sourceSchema, "001")
        XCTAssertEqual(backups.first?.targetSchema, "002")
        XCTAssertTrue(try value(in: try XCTUnwrap(reportedBackup)) == "from-wal")
        XCTAssertTrue(
            try failing.verifiedRecoveryBackups(identity: "family-b:user-b", storeURL: store).isEmpty
        )
        XCTAssertThrowsError(
            try failing.restoreVerifiedBackup(
                try XCTUnwrap(reportedBackup), identity: "family-b:user-b", storeURL: store
            )
        )

        try seed.activateForTesting(identity: identity, storeURL: store)
        try seed.write { db in
            try db.execute(sql: "UPDATE durable_values SET value='later' WHERE id=1")
        }
        seed.suspend()
        try failing.restoreVerifiedBackup(
            try XCTUnwrap(reportedBackup), identity: identity, storeURL: store
        )
        try seed.activateForTesting(identity: identity, storeURL: store)
        XCTAssertEqual(
            try seed.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM durable_values WHERE id=1")
            }, "from-wal")
        seed.suspend()
    }

    func testMigrationBackupRotationKeepsThreeVerifiedRecords() throws {
        let identity = "family-a:user-a"
        let store = root.appendingPathComponent("rotation/fitness.sqlite")
        for version in 1...5 {
            let identifiers = (1...version).map { String(format: "%03d", $0) }
            let database = FitnessDatabase(
                migrationIdentifiers: identifiers,
                migratorFactory: { Self.testMigrator(through: version) }
            )
            try database.activateForTesting(identity: identity, storeURL: store)
            database.suspend()
        }
        let inspector = FitnessDatabase(
            migrationIdentifiers: (1...5).map { String(format: "%03d", $0) },
            migratorFactory: { Self.testMigrator(through: 5) }
        )
        let backups = try inspector.verifiedRecoveryBackups(identity: identity, storeURL: store)
        XCTAssertEqual(backups.count, 3)
        XCTAssertEqual(Set(backups.map(\.targetSchema)), Set(["003", "004", "005"]))
    }

    func testBackupDiscoveryIgnoresFloodsAndRetainsNewestThreeValidRecords() throws {
        let identity = "family-a:user-a"
        let store = root.appendingPathComponent("flood/fitness.sqlite")
        for version in 1...5 {
            let database = FitnessDatabase(
                migrationIdentifiers: (1...version).map { String(format: "%03d", $0) },
                migratorFactory: { Self.testMigrator(through: version) }
            )
            try database.activateForTesting(identity: identity, storeURL: store)
            database.suspend()
        }

        let inspector = FitnessDatabase(
            migrationIdentifiers: (1...6).map { String(format: "%03d", $0) },
            migratorFactory: { Self.testMigrator(through: 6) }
        )
        let originalRecords = try inspector.verifiedRecoveryBackups(
            identity: identity,
            storeURL: store
        )
        let oldestValidDirectory = try XCTUnwrap(
            originalRecords.first { $0.targetSchema == "003" }
        ).url.deletingLastPathComponent()
        let backupsDirectory = store.deletingLastPathComponent()
            .appendingPathComponent("MigrationBackups", isDirectory: true)
        let providerDirectory = root.appendingPathComponent("provider-owned", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerDirectory,
            withIntermediateDirectories: true
        )
        let providerMarker = providerDirectory.appendingPathComponent("keep.txt")
        try Data("provider-data".utf8).write(to: providerMarker)

        var nearMisses: [URL] = []
        var symbolicLinks: [URL] = []
        for index in 0..<160 {
            let uuid = UUID().uuidString.lowercased()
            let nearMiss = backupsDirectory.appendingPathComponent(
                "\(Int64.max - Int64(index))-\(uuid).backup-provider",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nearMiss,
                withIntermediateDirectories: false
            )
            nearMisses.append(nearMiss)

            let symbolicLink = backupsDirectory.appendingPathComponent(
                "\(Int64.max - Int64(index))-\(UUID().uuidString.lowercased()).backup",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: symbolicLink,
                withDestinationURL: providerDirectory
            )
            symbolicLinks.append(symbolicLink)
        }
        let invalidExactCandidate = backupsDirectory.appendingPathComponent(
            "\(Int64.max)-\(UUID().uuidString.lowercased()).backup",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: invalidExactCandidate,
            withIntermediateDirectories: false
        )
        try Data("not-a-manifest".utf8).write(
            to: invalidExactCandidate.appendingPathComponent("manifest.json")
        )

        let beforeRotation = try inspector.verifiedRecoveryBackups(
            identity: identity,
            storeURL: store
        )
        XCTAssertEqual(beforeRotation.map(\.targetSchema), ["005", "004", "003"])

        try inspector.activateForTesting(identity: identity, storeURL: store)
        inspector.suspend()
        let afterRotation = try inspector.verifiedRecoveryBackups(
            identity: identity,
            storeURL: store
        )
        XCTAssertEqual(afterRotation.map(\.targetSchema), ["006", "005", "004"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldestValidDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalidExactCandidate.path))
        XCTAssertTrue(nearMisses.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(symbolicLinks.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: providerMarker), Data("provider-data".utf8))
    }

    func testRecoveryReconciliationIsBoundedOldestFirstAndNotStarvedByNearMisses() throws {
        let identity = "family-a:user-a"
        let ownerDirectory = root.appendingPathComponent("reconcile", isDirectory: true)
        let store = ownerDirectory.appendingPathComponent("fitness.sqlite")
        let backupsDirectory = ownerDirectory.appendingPathComponent(
            "MigrationBackups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: backupsDirectory,
            withIntermediateDirectories: true
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        for index in 0..<240 {
            let parent = index.isMultiple(of: 2) ? ownerDirectory : backupsDirectory
            let nearMiss = parent.appendingPathComponent(
                ".stage-provider-\(index)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nearMiss,
                withIntermediateDirectories: false
            )
        }

        var exactStages: [URL] = []
        for index in 0..<5 {
            let stage = backupsDirectory.appendingPathComponent(
                ".stage-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: stage,
                withIntermediateDirectories: false
            )
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-100 - Double(index))],
                ofItemAtPath: stage.path
            )
            exactStages.append(stage)
        }

        let providerDirectory = root.appendingPathComponent("outside-reconcile", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerDirectory,
            withIntermediateDirectories: true
        )
        let marker = providerDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let exactStageSymlink = backupsDirectory.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: exactStageSymlink,
            withDestinationURL: providerDirectory
        )

        let database = FitnessDatabase(rootDirectory: root)
        let report = try database.reconcileRecoveryArtifacts(
            identity: identity,
            storeURL: store,
            now: now,
            minimumAge: 10,
            maximumCandidates: 3,
            maximumEffects: 2
        )
        XCTAssertEqual(report.removedCount, 2)
        XCTAssertTrue(report.candidateLimitReached)
        XCTAssertTrue(report.effectLimitReached)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exactStages[4].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exactStages[3].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactStages[2].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exactStageSymlink.path))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    func testOpenReconcilesStaleCrashStagesButPreservesFreshAndRecoverableArtifacts() throws {
        let identity = "family-a:user-a"
        let ownerDirectory = root.appendingPathComponent("restart", isDirectory: true)
        let store = ownerDirectory.appendingPathComponent("fitness.sqlite")
        let backupsDirectory = ownerDirectory.appendingPathComponent(
            "MigrationBackups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: backupsDirectory,
            withIntermediateDirectories: true
        )
        let seed = FitnessDatabase(
            rootDirectory: root,
            migrationIdentifiers: ["001"],
            migratorFactory: { Self.testMigrator(through: 1) }
        )
        try seed.activateForTesting(identity: identity, storeURL: store)
        seed.suspend()

        let staleDate = Date().addingTimeInterval(-48 * 60 * 60)
        let staleBackupStage = backupsDirectory.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let freshBackupStage = backupsDirectory.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let staleRestoreStage = ownerDirectory.appendingPathComponent(
            ".restore-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let recoveryDirectory = ownerDirectory.appendingPathComponent(
            "Recovery-original-1-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        for directory in [staleBackupStage, freshBackupStage, staleRestoreStage, recoveryDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        try Data("recoverable".utf8).write(
            to: recoveryDirectory.appendingPathComponent("fitness.sqlite")
        )
        for directory in [staleBackupStage, staleRestoreStage, recoveryDirectory] {
            try FileManager.default.setAttributes(
                [.modificationDate: staleDate],
                ofItemAtPath: directory.path
            )
        }

        let restarted = FitnessDatabase(
            rootDirectory: root,
            migrationIdentifiers: ["001"],
            migratorFactory: { Self.testMigrator(through: 1) }
        )
        try restarted.activateForTesting(identity: identity, storeURL: store)
        restarted.suspend()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleBackupStage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleRestoreStage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshBackupStage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent("fitness.sqlite").path
            )
        )
    }

    func testRestoreReportsPartialRollbackFailureAndPreservesEveryRecoverySource() throws {
        let identity = "family-a:user-a"
        let store = root.appendingPathComponent("partial-rollback/fitness.sqlite")
        let seed = FitnessDatabase(
            migrationIdentifiers: ["001"],
            migratorFactory: { Self.testMigrator(through: 1) }
        )
        try seed.activateForTesting(identity: identity, storeURL: store)
        try seed.write { db in
            try db.execute(sql: "INSERT INTO durable_values(id,value) VALUES (1,'original')")
        }
        seed.suspend()

        let upgraded = FitnessDatabase(
            migrationIdentifiers: ["001", "002"],
            migratorFactory: { Self.testMigrator(through: 2) }
        )
        try upgraded.activateForTesting(identity: identity, storeURL: store)
        upgraded.suspend()
        let backup = try XCTUnwrap(
            upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store).first
        )

        let restoring = FitnessDatabase(
            migrationIdentifiers: ["001", "002"],
            migratorFactory: { Self.testMigrator(through: 2) },
            recoveryOperationHook: { operation, _, destination in
                if operation == .writeRestoredManifest {
                    throw NSError(
                        domain: "FitnessStorageDurabilityTests.primary",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Injected manifest failure"]
                    )
                }
                if operation == .restoreOriginal,
                    destination?.lastPathComponent == "fitness.sqlite"
                {
                    throw NSError(
                        domain: "FitnessStorageDurabilityTests.rollback",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Injected rollback failure"]
                    )
                }
            }
        )
        var recoveryPaths: [URL] = []
        XCTAssertThrowsError(
            try restoring.restoreVerifiedBackup(
                backup.url,
                identity: identity,
                storeURL: store
            )
        ) { error in
            guard
                case FitnessDatabaseError.recoveryFailed(
                    let
                        reportedStore,
                    let
                        reportedBackup,
                    let
                        paths,
                    let
                        underlying
                ) = error
            else {
                return XCTFail("Expected an aggregate recovery failure, received \(error)")
            }
            XCTAssertEqual(reportedStore, store)
            XCTAssertEqual(reportedBackup, backup.url)
            XCTAssertTrue(underlying.localizedDescription.contains("Injected manifest failure"))
            XCTAssertTrue(underlying.localizedDescription.contains("Injected rollback failure"))
            recoveryPaths = paths
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.url.path))
        let recoveryDirectory = try XCTUnwrap(
            recoveryPaths.first { $0.lastPathComponent.hasPrefix("Recovery-original-") }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent("fitness.sqlite").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent("failed-restored.sqlite").path
            )
        )
        XCTAssertEqual(
            try restoring.verifiedRecoveryBackups(identity: identity, storeURL: store),
            [backup]
        )

        let restarted = FitnessDatabase(
            migrationIdentifiers: ["001", "002"],
            migratorFactory: { Self.testMigrator(through: 2) }
        )
        XCTAssertThrowsError(
            try restarted.activateForTesting(identity: identity, storeURL: store)
        ) { error in
            guard case FitnessDatabaseError.migrationFailed = error else {
                return XCTFail("Expected restart to fail closed, received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: recoveryDirectory.appendingPathComponent("fitness.sqlite").path
            )
        )
    }

    private static func testMigrator(
        through version: Int,
        failingAt: Int? = nil
    ) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for number in 1...version {
            let identifier = String(format: "%03d", number)
            migrator.registerMigration(identifier) { db in
                if failingAt == number {
                    throw NSError(
                        domain: "FitnessStorageDurabilityTests",
                        code: number,
                        userInfo: [NSLocalizedDescriptionKey: "Injected migration failure"]
                    )
                }
                if number == 1 {
                    try db.execute(
                        sql: """
                            CREATE TABLE fitness_metadata (
                                key TEXT PRIMARY KEY NOT NULL,
                                value TEXT NOT NULL
                            );
                            CREATE TABLE durable_values (
                                id INTEGER PRIMARY KEY NOT NULL,
                                value TEXT NOT NULL
                            );
                            """)
                } else {
                    try db.execute(sql: "CREATE TABLE migration_\(number) (id INTEGER PRIMARY KEY)")
                }
            }
        }
        return migrator
    }

    private func value(in store: URL) throws -> String? {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: store.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM durable_values WHERE id=1")
        }
    }
}

final class FitnessPendingFITInboxDurabilityTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FitnessFITQueue-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "FitnessFITQueue.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testConcurrentProducersPublishDistinctCompleteItems() throws {
        let identity = "family-a:user-a"
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let lock = NSLock()
        var ids: [String] = []
        var failures: [Error] = []
        // Foundation may parse this exact formatted millisecond one millisecond
        // lower internally. Canonical validation must accept the wire spelling.
        let now = Date(timeIntervalSince1970: 1_800_000_000.002)
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do {
                let source = root.appendingPathComponent("source-\(index).fit")
                try Data(repeating: UInt8(index), count: 512 + index).write(to: source)
                let id = try FitnessPendingFITInbox.enqueueFIT(
                    at: source,
                    context: context,
                    now: now
                )
                lock.lock()
                ids.append(id)
                lock.unlock()
            } catch {
                lock.lock()
                failures.append(error)
                lock.unlock()
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "Concurrent enqueue failures: \(failures.map { String(describing: $0) })"
        )
        XCTAssertEqual(Set(ids).count, 8)

        var claimed = 0
        while let claim = try FitnessPendingFITInbox.claimNextOwned(
            for: identity, context: context
        ) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: claim.payload.filePath))
            try FitnessPendingFITInbox.acknowledge(claim, context: context)
            claimed += 1
        }
        XCTAssertEqual(claimed, 8)
    }

    func testExpiredClaimIsRecoveredAndOldLeaseCannotAcknowledgeNewClaim() throws {
        let identity = "family-a:user-a"
        var limits = FitnessPendingFITInbox.Limits()
        limits.claimLifetime = 1
        let context = FitnessPendingFITInbox.Context(
            containerURL: root, defaults: defaults, limits: limits
        )
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let source = root.appendingPathComponent("crash.fit")
        try Data(repeating: 0x2A, count: 1_024).write(to: source)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try FitnessPendingFITInbox.enqueueFIT(at: source, context: context, now: start)
        let first = try XCTUnwrap(
            FitnessPendingFITInbox.claimNextOwned(
                for: identity, context: context, now: start
            ))
        _ = try FitnessPendingFITInbox.reconcile(
            context: context, now: start.addingTimeInterval(2)
        )
        let second = try XCTUnwrap(
            FitnessPendingFITInbox.claimNextOwned(
                for: identity, context: context, now: start.addingTimeInterval(2)
            ))
        XCTAssertNotEqual(first.leaseID, second.leaseID)
        XCTAssertThrowsError(try FitnessPendingFITInbox.acknowledge(first, context: context))
        try FitnessPendingFITInbox.acknowledge(second, context: context)
    }

    func testExpiredClaimIsRetainedWhenMetadataInspectionIsTemporarilyDenied() throws {
        let identity = "family-a:user-a"
        var limits = FitnessPendingFITInbox.Limits()
        limits.claimLifetime = 1
        let context = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            limits: limits
        )
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let source = root.appendingPathComponent("protected.fit")
        try Data(repeating: 0x41, count: 1_024).write(to: source)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try FitnessPendingFITInbox.enqueueFIT(at: source, context: context, now: start)
        let claim = try XCTUnwrap(
            FitnessPendingFITInbox.claimNextOwned(
                for: identity,
                context: context,
                now: start
            )
        )
        let claimedDirectory = URL(fileURLWithPath: claim.payload.filePath)
            .deletingLastPathComponent()
        let metadata = claimedDirectory.appendingPathComponent("metadata.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: metadata.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: metadata.path
            )
        }

        XCTAssertEqual(
            try FitnessPendingFITInbox.reconcile(
                context: context,
                now: start.addingTimeInterval(2)
            ),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: claim.payload.filePath))
    }

    func testOwnerIsolationAndInboxCapsAreEnforced() throws {
        var limits = FitnessPendingFITInbox.Limits()
        limits.maximumItems = 1
        let context = FitnessPendingFITInbox.Context(
            containerURL: root, defaults: defaults, limits: limits
        )
        let sourceA = root.appendingPathComponent("a.fit")
        let sourceB = root.appendingPathComponent("b.fit")
        try Data(repeating: 1, count: 64).write(to: sourceA)
        try Data(repeating: 2, count: 64).write(to: sourceB)
        try FitnessPendingFITInbox.setActiveIdentity("family-a:user-a", context: context)
        _ = try FitnessPendingFITInbox.enqueueFIT(at: sourceA, context: context)
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(at: sourceB, context: context)
        )

        try FitnessPendingFITInbox.setActiveIdentity("family-b:user-b", context: context)
        XCTAssertNil(
            try FitnessPendingFITInbox.claimNextOwned(
                for: "family-b:user-b", context: context
            ))
        try FitnessPendingFITInbox.setActiveIdentity("family-a:user-a", context: context)
        XCTAssertNotNil(
            try FitnessPendingFITInbox.claimNextOwned(
                for: "family-a:user-a", context: context
            ))
    }

    func testExplicitProducerOwnerMustMatchExactDurableActiveIdentity() throws {
        let ownerA = "family-a:user-a"
        let ownerB = "family-b:user-b"
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        let sourceA = root.appendingPathComponent("explicit-a.fit")
        let sourceB = root.appendingPathComponent("explicit-b.fit")
        let sourceAfterClear = root.appendingPathComponent("explicit-after-clear.fit")
        try Data(repeating: 0xA1, count: 512).write(to: sourceA)
        try Data(repeating: 0xB2, count: 512).write(to: sourceB)
        try Data(repeating: 0xC3, count: 512).write(to: sourceAfterClear)

        try FitnessPendingFITInbox.setActiveIdentity(ownerB, context: context)
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(
                at: sourceA,
                ownerIdentity: ownerA,
                context: context
            )
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .inactiveIdentity = inboxError else {
                return XCTFail("An explicit owner must not bypass active owner B")
            }
        }
        _ = try FitnessPendingFITInbox.enqueueFIT(
            at: sourceB,
            ownerIdentity: ownerB,
            context: context
        )

        try FitnessPendingFITInbox.clearActiveIdentity(context: context)
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(
                at: sourceAfterClear,
                ownerIdentity: ownerB,
                context: context
            )
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .inactiveIdentity = inboxError else {
                return XCTFail("An explicit owner requires a durable active owner")
            }
        }
    }

    func testLegacyDuplicateIsRetainedUntilBothAssetsMatchPublishedSHA() throws {
        let identity = "family-a:user-a"
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let original = Data(repeating: 0xD4, count: 1_024)
        let source = root.appendingPathComponent("duplicate.fit")
        try original.write(to: source)
        let id = try FitnessPendingFITInbox.enqueueFIT(
            at: source,
            context: context,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let durable = try XCTUnwrap(
            FitnessPendingFITInbox.ownedRecoveryEntries(
                identity: identity,
                defaults: defaults,
                containerURL: root
            ).first(where: { $0.id == id })
        )
        let durableAsset = URL(fileURLWithPath: durable.filePath)
        let legacyRoot = root.appendingPathComponent(
            FitnessPendingFITInbox.legacyDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyAsset = legacyRoot.appendingPathComponent("duplicate.fit")
        try original.write(to: legacyAsset)
        let legacy = SharedFitnessFITPayload(
            id: id,
            filePath: legacyAsset.path,
            originalFilename: durable.originalFilename,
            byteCount: durable.byteCount,
            createdAt: durable.createdAt,
            ownerIdentity: identity
        )
        let encodedLegacy = try JSONEncoder().encode([legacy])
        defaults.set(encodedLegacy, forKey: FitnessPendingFITInbox.queueKey)

        // Matching metadata is insufficient proof if the durable copy no longer
        // matches the SHA published with the item.
        try Data(repeating: 0xE5, count: original.count).write(to: durableAsset)
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.claimNextOwned(for: identity, context: context)
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .invalidFile = inboxError else {
                return XCTFail("Expected mismatched duplicate bytes to fail closed")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyAsset.path))
        XCTAssertEqual(defaults.data(forKey: FitnessPendingFITInbox.queueKey), encodedLegacy)

        try original.write(to: durableAsset)
        let claim = try XCTUnwrap(
            FitnessPendingFITInbox.claimNextOwned(for: identity, context: context)
        )
        XCTAssertEqual(claim.payload.id, id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAsset.path))
        XCTAssertNil(defaults.data(forKey: FitnessPendingFITInbox.queueKey))
        try FitnessPendingFITInbox.acknowledge(claim, context: context)
    }

    func testAssetTamperingCannotBeAcknowledgedAsDurablyStaged() throws {
        let identity = "family-a:user-a"
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let source = root.appendingPathComponent("tamper.fit")
        try Data(repeating: 7, count: 128).write(to: source)
        _ = try FitnessPendingFITInbox.enqueueFIT(at: source, context: context)
        let claim = try XCTUnwrap(
            FitnessPendingFITInbox.claimNextOwned(
                for: identity, context: context
            ))
        try Data(repeating: 8, count: 128).write(to: URL(fileURLWithPath: claim.payload.filePath))
        XCTAssertThrowsError(try FitnessPendingFITInbox.acknowledge(claim, context: context))
        _ = try FitnessPendingFITInbox.reconcile(context: context)
        XCTAssertNil(
            try FitnessPendingFITInbox.claimNextOwned(
                for: identity, context: context
            ))
    }

    func testOwnerPurgeInvalidatesProducerPausedBeforeHashAndReservation() throws {
        let identity = "family-a:user-a"
        let source = root.appendingPathComponent("pre-hash.fit")
        try Data(repeating: 0x91, count: 4_096).write(to: source)
        let gate = FITProducerBoundaryGate()
        let context = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            producerBoundaryDidCapture: gate.pause
        )
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let results = FITEnqueueResultStore()
        let producer = DispatchGroup()
        producer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FitnessPendingFITInbox.enqueueFIT(
                    at: source,
                    context: context
                )
            }
            results.store(result, for: identity)
            producer.leave()
        }

        XCTAssertTrue(gate.waitUntilCaptured(timeout: 5))
        defer { gate.release() }
        try FitnessPendingFITInbox.purgeOwned(
            identity: identity,
            defaults: defaults,
            containerURL: root
        )
        gate.release()
        XCTAssertEqual(producer.wait(timeout: .now() + 5), .success)
        guard case .failure? = results.result(for: identity) else {
            return XCTFail("A pre-purge producer must not reserve or publish afterward")
        }
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                identity: identity,
                defaults: defaults,
                containerURL: root
            ),
            0
        )
    }

    func testSameOwnerReactivationAfterInterruptedClearInvalidatesOldProducer() throws {
        let identity = "family-a:user-a"
        let source = root.appendingPathComponent("interrupted-clear.fit")
        try Data(repeating: 0x92, count: 4_096).write(to: source)
        let gate = FITProducerBoundaryGate()
        let context = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            producerBoundaryDidCapture: gate.pause
        )
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let results = FITEnqueueResultStore()
        let producer = DispatchGroup()
        producer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            results.store(
                Result {
                    try FitnessPendingFITInbox.enqueueFIT(at: source, context: context)
                },
                for: identity
            )
            producer.leave()
        }

        XCTAssertTrue(gate.waitUntilCaptured(timeout: 5))
        defer { gate.release() }
        // Simulate a clear that removed the mirror but could not update the
        // protected generation file.
        defaults.removeObject(forKey: FitnessPendingFITInbox.activeIdentityKey)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        gate.release()

        XCTAssertEqual(producer.wait(timeout: .now() + 5), .success)
        guard case .failure? = results.result(for: identity) else {
            return XCTFail("Same-owner reactivation must invalidate pre-clear work")
        }
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                identity: identity,
                defaults: defaults,
                containerURL: root
            ),
            0
        )
    }

    func testStaleDefaultsCannotReactivatePurgedDurableOwner() throws {
        let identity = "family-a:user-a"
        // Seed the compatibility mirror without durable state to exercise the
        // one-time upgrade path from the previous app release.
        defaults.set(identity, forKey: FitnessPendingFITInbox.activeIdentityKey)
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        let firstSource = root.appendingPathComponent("before-purge.fit")
        let staleSource = root.appendingPathComponent("stale-owner.fit")
        try Data(repeating: 0x81, count: 512).write(to: firstSource)
        try Data(repeating: 0x82, count: 512).write(to: staleSource)
        _ = try FitnessPendingFITInbox.enqueueFIT(at: firstSource, context: context)
        try FitnessPendingFITInbox.purgeOwned(
            identity: identity,
            defaults: defaults,
            containerURL: root
        )

        // Simulate a still-running extension whose suite cache has not observed
        // the purge. Durable state remains authoritative and refuses the owner.
        defaults.set(identity, forKey: FitnessPendingFITInbox.activeIdentityKey)
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(at: staleSource, context: context)
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .inactiveIdentity = inboxError else {
                return XCTFail("Expected the stale owner boundary to fail closed")
            }
        }
        XCTAssertEqual(
            FitnessPendingFITInbox.pendingCount(
                identity: identity,
                defaults: defaults,
                containerURL: root
            ),
            0
        )
    }

    func testOwnerPurgeInvalidatesPausedProducerAndPreservesOtherOwnerStage() throws {
        let ownerA = "family-a:user-a"
        let ownerB = "family-b:user-b"
        let sourceA = root.appendingPathComponent("owner-a.fit")
        let sourceB = root.appendingPathComponent("owner-b.fit")
        try Data(repeating: 0xA1, count: 4_096).write(to: sourceA)
        try Data(repeating: 0xB2, count: 4_096).write(to: sourceB)
        let fileManager = PausingFITCopyFileManager(
            pausedSources: [sourceA.lastPathComponent]
        )
        let context = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            fileManager: fileManager
        )
        try FitnessPendingFITInbox.setActiveIdentity(ownerB, context: context)
        let ownerBID = try FitnessPendingFITInbox.enqueueFIT(
            at: sourceB,
            context: context
        )
        let inbox = root.appendingPathComponent(
            FitnessPendingFITInbox.directoryName,
            isDirectory: true
        )
        let readyOwnerB = inbox
            .appendingPathComponent(FitnessPendingFITInbox.readyDirectoryName, isDirectory: true)
            .appendingPathComponent("\(ownerBID).fititem", isDirectory: true)
        let temporary = inbox.appendingPathComponent(
            FitnessPendingFITInbox.temporaryDirectoryName,
            isDirectory: true
        )
        let stagedOwnerB = temporary.appendingPathComponent(
            ".stage-\(ownerBID)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: readyOwnerB, to: stagedOwnerB)

        try FitnessPendingFITInbox.setActiveIdentity(ownerA, context: context)
        let results = FITEnqueueResultStore()
        let producer = DispatchGroup()
        producer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FitnessPendingFITInbox.enqueueFIT(
                    at: sourceA,
                    context: context
                )
            }
            results.store(result, for: ownerA)
            producer.leave()
        }

        XCTAssertTrue(fileManager.waitUntilAllCopiesStart(timeout: 5))
        defer { fileManager.releaseCopies() }
        try FitnessPendingFITInbox.purgeOwned(
            identity: ownerA,
            defaults: defaults,
            containerURL: root,
            fileManager: fileManager
        )

        let reservations = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(reservations.count, 1)
        XCTAssertEqual(reservations.first, stagedOwnerB)
        let metadata = stagedOwnerB.appendingPathComponent("metadata.json")
        let metadataObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: metadata))
                as? [String: Any]
        )
        XCTAssertEqual(metadataObject["ownerIdentity"] as? String, ownerB)

        fileManager.releaseCopies()
        XCTAssertEqual(producer.wait(timeout: .now() + 5), .success)
        guard case .failure? = results.result(for: ownerA) else {
            return XCTFail("The purged owner's producer must fail closed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedOwnerB.path))
    }

    func testInFlightReservationConsumesCapacityBeforeLargeCopyCompletes() throws {
        let firstOwner = "family-a:user-a"
        let firstSource = root.appendingPathComponent("reserved.fit")
        let secondSource = root.appendingPathComponent("over-capacity.fit")
        try Data(repeating: 0x71, count: 4_096).write(to: firstSource)
        try Data(repeating: 0x72, count: 4_096).write(to: secondSource)
        let fileManager = PausingFITCopyFileManager(
            pausedSources: [firstSource.lastPathComponent]
        )
        var limits = FitnessPendingFITInbox.Limits()
        limits.maximumItems = 1
        let context = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            fileManager: fileManager,
            limits: limits
        )
        try FitnessPendingFITInbox.setActiveIdentity(firstOwner, context: context)
        let results = FITEnqueueResultStore()
        let firstProducer = DispatchGroup()
        firstProducer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FitnessPendingFITInbox.enqueueFIT(
                    at: firstSource,
                    context: context
                )
            }
            results.store(result, for: firstOwner)
            firstProducer.leave()
        }

        XCTAssertTrue(fileManager.waitUntilAllCopiesStart(timeout: 5))
        defer { fileManager.releaseCopies() }
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(
                at: secondSource,
                context: context
            )
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .inboxFull = inboxError else {
                return XCTFail("Expected the live reservation to consume the item cap")
            }
        }
        fileManager.releaseCopies()
        XCTAssertEqual(firstProducer.wait(timeout: .now() + 5), .success)
        guard case .success? = results.result(for: firstOwner) else {
            return XCTFail("The original reserved producer should publish")
        }
    }

    func testCapacityAndPurgeFailClosedWhenDurableInspectionIsDenied() throws {
        let identity = "family-a:user-a"
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let source = root.appendingPathComponent("private.fit")
        let nextSource = root.appendingPathComponent("next.fit")
        try Data(repeating: 0x31, count: 512).write(to: source)
        try Data(repeating: 0x32, count: 512).write(to: nextSource)
        let itemID = try FitnessPendingFITInbox.enqueueFIT(
            at: source,
            context: context
        )
        let metadata = metadataURL(forReadyItem: itemID)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: metadata.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: metadata.path
            )
        }

        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(
                at: nextSource,
                context: context
            )
        )
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.purgeOwned(
                identity: identity,
                defaults: defaults,
                containerURL: root
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.path))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: metadata.path
        )
        try FitnessPendingFITInbox.purgeOwned(
            identity: identity,
            defaults: defaults,
            containerURL: root
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
    }

    func testPrivacyPurgesFailClosedWhenContainerIsUnavailable() throws {
        let identity = "family-a:user-a"
        // Model a legacy defaults-only installation whose App Group container
        // cannot currently be resolved.
        defaults.set(identity, forKey: FitnessPendingFITInbox.activeIdentityKey)
        let legacy = SharedFitnessFITPayload(
            id: UUID().uuidString,
            filePath: root.appendingPathComponent("legacy.fit").path,
            originalFilename: "legacy.fit",
            byteCount: 512,
            createdAt: "2027-01-15T12:00:00.000Z",
            ownerIdentity: identity
        )
        let encodedQueue = try JSONEncoder().encode([legacy])
        defaults.set(encodedQueue, forKey: FitnessPendingFITInbox.queueKey)

        XCTAssertThrowsError(
            try FitnessPendingFITInbox.purgeOwned(
                identity: identity,
                defaults: defaults,
                containerURL: nil
            )
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .containerUnavailable = inboxError else {
                return XCTFail("Expected a container-unavailable failure")
            }
        }
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.purgeUnclaimed(
                defaults: defaults,
                containerURL: nil
            )
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .containerUnavailable = inboxError else {
                return XCTFail("Expected a container-unavailable failure")
            }
        }
        XCTAssertEqual(defaults.string(
            forKey: FitnessPendingFITInbox.activeIdentityKey
        ), identity)
        XCTAssertEqual(defaults.data(forKey: FitnessPendingFITInbox.queueKey), encodedQueue)
    }

    func testLegacyQueueBoundsFailClosedAndRetainOriginalBytes() throws {
        let identity = "family-a:user-a"
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let source = root.appendingPathComponent("bounded.fit")
        try Data(repeating: 0xC3, count: 512).write(to: source)

        // This is valid JSON for an empty array, so only the byte gate should
        // reject it before JSONDecoder allocates for the oversized value.
        var oversizedQueue = Data("[".utf8)
        oversizedQueue.append(Data(repeating: 0x20, count: 1_024 * 1_024))
        oversizedQueue.append(contentsOf: "]".utf8)
        defaults.set(oversizedQueue, forKey: FitnessPendingFITInbox.queueKey)
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(at: source, context: context)
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .coordinationFailed = inboxError else {
                return XCTFail("Expected the oversized legacy queue to fail closed")
            }
        }
        XCTAssertEqual(
            defaults.data(forKey: FitnessPendingFITInbox.queueKey),
            oversizedQueue
        )

        let legacyRoot = root.appendingPathComponent(
            FitnessPendingFITInbox.legacyDirectoryName,
            isDirectory: true
        )
        let tooManyEntries = (0...1_024).map { index in
            SharedFitnessFITPayload(
                id: UUID().uuidString,
                filePath: legacyRoot.appendingPathComponent("\(index).fit").path,
                originalFilename: "\(index).fit",
                byteCount: 1,
                createdAt: "2027-01-15T12:00:00.000Z",
                ownerIdentity: identity
            )
        }
        let overCountQueue = try JSONEncoder().encode(tooManyEntries)
        XCTAssertLessThan(overCountQueue.count, 1_024 * 1_024)
        defaults.set(overCountQueue, forKey: FitnessPendingFITInbox.queueKey)
        XCTAssertTrue(
            FitnessPendingFITInbox.ownedRecoveryEntries(
                identity: identity,
                defaults: defaults,
                containerURL: root
            ).isEmpty
        )
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.enqueueFIT(at: source, context: context)
        ) { error in
            guard let inboxError = error as? FitnessPendingFITInboxError,
                  case .coordinationFailed = inboxError else {
                return XCTFail("Expected the legacy entry-count bound to fail closed")
            }
        }
        XCTAssertEqual(
            defaults.data(forKey: FitnessPendingFITInbox.queueKey),
            overCountQueue
        )
    }

    func testLegacyRootSymlinkCannotReadOrDeleteOutsideAppGroupInbox() throws {
        let identity = "family-a:user-a"
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FitnessFITOutside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideAsset = outside.appendingPathComponent("owned.fit")
        let sentinel = Data(repeating: 0xD4, count: 512)
        try sentinel.write(to: outsideAsset)

        let legacyRoot = root.appendingPathComponent(
            FitnessPendingFITInbox.legacyDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: legacyRoot,
            withDestinationURL: outside
        )
        let legacy = SharedFitnessFITPayload(
            id: UUID().uuidString,
            filePath: legacyRoot.appendingPathComponent("owned.fit").path,
            originalFilename: "owned.fit",
            byteCount: sentinel.count,
            createdAt: "2027-01-15T12:00:00.000Z",
            ownerIdentity: identity
        )
        let encodedQueue = try JSONEncoder().encode([legacy])
        defaults.set(encodedQueue, forKey: FitnessPendingFITInbox.queueKey)
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)

        XCTAssertNil(
            try FitnessPendingFITInbox.claimNextOwned(for: identity, context: context)
        )
        XCTAssertEqual(try Data(contentsOf: outsideAsset), sentinel)
        XCTAssertThrowsError(
            try FitnessPendingFITInbox.purgeOwned(
                identity: identity,
                defaults: defaults,
                containerURL: root
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideAsset), sentinel)
        XCTAssertEqual(defaults.data(forKey: FitnessPendingFITInbox.queueKey), encodedQueue)
    }

    func testFractionalClaimExpiryMatchesAdvertisedLease() throws {
        let identity = "family-a:user-a"
        var limits = FitnessPendingFITInbox.Limits()
        limits.claimLifetime = 0.5
        let context = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            limits: limits
        )
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let source = root.appendingPathComponent("fractional.fit")
        try Data(repeating: 0x44, count: 512).write(to: source)
        let start = Date(timeIntervalSince1970: 1_800_000_000.125_321)
        _ = try FitnessPendingFITInbox.enqueueFIT(at: source, context: context, now: start)
        let claim = try XCTUnwrap(
            FitnessPendingFITInbox.claimNextOwned(
                for: identity,
                context: context,
                now: start
            )
        )
        XCTAssertEqual(
            claim.expiresAt.timeIntervalSince1970,
            1_800_000_000.625_321,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try FitnessPendingFITInbox.reconcile(
                context: context,
                now: start.addingTimeInterval(0.49)
            ),
            0
        )
        XCTAssertEqual(
            try FitnessPendingFITInbox.reconcile(
                context: context,
                now: start.addingTimeInterval(0.51)
            ),
            1
        )
    }

    func testMalformedAndNoncanonicalCreatedDatesCannotInfluenceFIFO() throws {
        let identity = "family-a:user-a"
        let context = FitnessPendingFITInbox.Context(containerURL: root, defaults: defaults)
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let malformedSource = root.appendingPathComponent("malformed.fit")
        let noncanonicalSource = root.appendingPathComponent("noncanonical.fit")
        let validSource = root.appendingPathComponent("valid.fit")
        try Data(repeating: 0x51, count: 256).write(to: malformedSource)
        try Data(repeating: 0x52, count: 256).write(to: noncanonicalSource)
        try Data(repeating: 0x53, count: 256).write(to: validSource)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let malformedID = try FitnessPendingFITInbox.enqueueFIT(
            at: malformedSource,
            context: context,
            now: start
        )
        let noncanonicalID = try FitnessPendingFITInbox.enqueueFIT(
            at: noncanonicalSource,
            context: context,
            now: start.addingTimeInterval(1)
        )
        let validID = try FitnessPendingFITInbox.enqueueFIT(
            at: validSource,
            context: context,
            now: start.addingTimeInterval(2)
        )
        try replaceCreatedAt("0000", forReadyItem: malformedID)
        try replaceCreatedAt(
            "2027-01-15T12:00:00.125000Z",
            forReadyItem: noncanonicalID
        )

        let claim = try XCTUnwrap(
            FitnessPendingFITInbox.claimNextOwned(for: identity, context: context)
        )
        XCTAssertEqual(claim.payload.id, validID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: metadataURL(forReadyItem: malformedID).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: metadataURL(forReadyItem: noncanonicalID).path
        ))
        try FitnessPendingFITInbox.acknowledge(claim, context: context)
    }

    func testReconciliationBudgetsStaleStagesAndNeverDeletesSymlinkTargets() throws {
        var limits = FitnessPendingFITInbox.Limits()
        limits.temporaryLifetime = 10
        limits.maximumReconciliationCandidates = 3
        limits.maximumReconciliationMutations = 2
        let context = FitnessPendingFITInbox.Context(
            containerURL: root, defaults: defaults, limits: limits
        )
        let now = Date()
        _ = try FitnessPendingFITInbox.reconcile(context: context, now: now)
        let temporary =
            root
            .appendingPathComponent(FitnessPendingFITInbox.directoryName, isDirectory: true)
            .appendingPathComponent(FitnessPendingFITInbox.temporaryDirectoryName, isDirectory: true)
        let stale = (0..<5).map { _ in
            temporary.appendingPathComponent(
                ".stage-\(UUID().uuidString)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        }
        for directory in stale {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-20)],
                ofItemAtPath: directory.path
            )
        }
        let providerTarget = root.appendingPathComponent("provider-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: providerTarget, withIntermediateDirectories: true)
        let symbolicLink = temporary.appendingPathComponent(
            ".stage-\(UUID().uuidString)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: providerTarget)
        let unrelatedStage = temporary.appendingPathComponent(
            ".stage-provider-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unrelatedStage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-20)],
            ofItemAtPath: unrelatedStage.path
        )
        let inboxRoot = root.appendingPathComponent(
            FitnessPendingFITInbox.directoryName,
            isDirectory: true
        )
        let unrelatedReady =
            inboxRoot
            .appendingPathComponent(FitnessPendingFITInbox.readyDirectoryName, isDirectory: true)
            .appendingPathComponent("provider.fititem", isDirectory: true)
        let unrelatedClaimed =
            inboxRoot
            .appendingPathComponent(FitnessPendingFITInbox.claimedDirectoryName, isDirectory: true)
            .appendingPathComponent("provider.fititem.claim.0.not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedReady, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedClaimed, withIntermediateDirectories: true)

        XCTAssertEqual(try FitnessPendingFITInbox.reconcile(context: context, now: now), 2)
        XCTAssertEqual(stale.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 3)
        XCTAssertEqual(try FitnessPendingFITInbox.reconcile(context: context, now: now), 2)
        XCTAssertEqual(stale.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
        XCTAssertEqual(try FitnessPendingFITInbox.reconcile(context: context, now: now), 1)
        XCTAssertTrue(stale.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: providerTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedStage.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedReady.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedClaimed.path))
    }

    func testForeignReservationLeaseSurvivesFutureClockUntilWriterCloses() throws {
        let identity = "family-a:user-a"
        var limits = FitnessPendingFITInbox.Limits()
        limits.temporaryLifetime = 1
        let context = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            limits: limits
        )
        try FitnessPendingFITInbox.setActiveIdentity(identity, context: context)
        let source = root.appendingPathComponent("leased.fit")
        try Data(repeating: 0x61, count: 512).write(to: source)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = try FitnessPendingFITInbox.enqueueFIT(
            at: source,
            context: context,
            now: start
        )
        let inbox = root.appendingPathComponent(
            FitnessPendingFITInbox.directoryName,
            isDirectory: true
        )
        let ready = inbox
            .appendingPathComponent(FitnessPendingFITInbox.readyDirectoryName, isDirectory: true)
            .appendingPathComponent("\(id).fititem", isDirectory: true)
        let temporary = inbox.appendingPathComponent(
            FitnessPendingFITInbox.temporaryDirectoryName,
            isDirectory: true
        )
        let staged = temporary.appendingPathComponent(
            ".stage-\(id)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: ready, to: staged)
        let leaseURL = staged.appendingPathComponent(".reservation.lock")
        var descriptor = open(
            leaseURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer {
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }

        let foreignContext = FitnessPendingFITInbox.Context(
            containerURL: root,
            defaults: defaults,
            limits: limits
        )
        XCTAssertEqual(
            try FitnessPendingFITInbox.reconcile(
                context: foreignContext,
                now: start.addingTimeInterval(10_000)
            ),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
        XCTAssertEqual(
            try FitnessPendingFITInbox.reconcile(
                context: foreignContext,
                now: start.addingTimeInterval(10_000)
            ),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    private func metadataURL(forReadyItem id: String) -> URL {
        root
            .appendingPathComponent(FitnessPendingFITInbox.directoryName, isDirectory: true)
            .appendingPathComponent(FitnessPendingFITInbox.readyDirectoryName, isDirectory: true)
            .appendingPathComponent("\(id).fititem", isDirectory: true)
            .appendingPathComponent("metadata.json")
    }

    private func replaceCreatedAt(_ value: String, forReadyItem id: String) throws {
        let url = metadataURL(forReadyItem: id)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["createdAt"] = value
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: [.atomic])
    }
}
