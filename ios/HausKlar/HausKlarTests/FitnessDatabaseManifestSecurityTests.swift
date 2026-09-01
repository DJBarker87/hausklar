import Foundation
import GRDB
import XCTest

@testable import HausKlar

final class FitnessDatabaseManifestSecurityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FitnessManifestSecurity-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func testOversizedStoreManifestFailsClosedBeforeDecode() throws {
        let identity = "family-a:user-a"
        let database = makeDatabase(through: 1)
        try database.activate(identity: identity, legacyOwnerProof: nil)
        database.suspend()
        let manifest = storeManifestURL(identity: identity)
        try Data(
            repeating: 0x7B,
            count: FitnessDatabase.maximumManifestByteCount + 1
        ).write(to: manifest, options: .atomic)

        let reopened = makeDatabase(through: 1)
        XCTAssertThrowsError(try reopened.activate(identity: identity, legacyOwnerProof: nil)) {
            guard case FitnessDatabaseError.unverifiedLegacyStore = $0 else {
                return XCTFail("Expected an unverified store, received \($0)")
            }
        }
        XCTAssertNil(reopened.activeIdentity)
    }

    func testValidStoreManifestBehindSymbolicLinkFailsClosed() throws {
        let identity = "family-a:user-a"
        let database = makeDatabase(through: 1)
        try database.activate(identity: identity, legacyOwnerProof: nil)
        database.suspend()
        let manifest = storeManifestURL(identity: identity)
        let original = try Data(contentsOf: manifest)
        let target = root.appendingPathComponent("outside-valid-store-manifest.json")
        try original.write(to: target, options: .atomic)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: target)

        let reopened = makeDatabase(through: 1)
        XCTAssertThrowsError(try reopened.activate(identity: identity, legacyOwnerProof: nil)) {
            guard case FitnessDatabaseError.unverifiedLegacyStore = $0 else {
                return XCTFail("Expected an unverified store, received \($0)")
            }
        }
        XCTAssertNil(reopened.activeIdentity)
    }

    func testCorruptLegacyManifestIsNotOverwrittenEvenWithExactOwnerProof() throws {
        let identity = "family-a:user-a"
        let legacyDirectory = root.appendingPathComponent(
            FitnessDatabase.legacyIdentityDirectoryName(identity),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyStore = legacyDirectory.appendingPathComponent("fitness.sqlite")
        try Data("recoverable legacy bytes".utf8).write(to: legacyStore)
        let manifest = legacyDirectory.appendingPathComponent("store-manifest.json")
        let corruptManifest = Data("{not-valid-json".utf8)
        try corruptManifest.write(to: manifest)

        let database = makeDatabase(through: 1)
        XCTAssertThrowsError(
            try database.activate(identity: identity, legacyOwnerProof: identity)
        ) { error in
            guard case FitnessDatabaseError.unverifiedLegacyStore = error else {
                return XCTFail("Expected an unverified legacy store, received \(error)")
            }
        }

        let canonicalDirectory = root.appendingPathComponent(
            FitnessDatabase.identityDirectoryName(identity),
            isDirectory: true
        )
        XCTAssertNil(database.activeIdentity)
        XCTAssertEqual(try Data(contentsOf: manifest), corruptManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStore.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonicalDirectory.path))
    }

    func testCorruptLegacyManifestIsNotDeletedEvenWithExactOwnerProof() throws {
        let identity = "family-a:user-a"
        let database = makeDatabase(through: 1)
        try database.activate(identity: identity, legacyOwnerProof: nil)
        database.suspend()
        let canonicalDirectory = root.appendingPathComponent(
            FitnessDatabase.identityDirectoryName(identity),
            isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDirectory.path))

        let legacyDirectory = root.appendingPathComponent(
            FitnessDatabase.legacyIdentityDirectoryName(identity),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyStore = legacyDirectory.appendingPathComponent("fitness.sqlite")
        let storeBytes = Data("recoverable legacy bytes".utf8)
        try storeBytes.write(to: legacyStore)
        let manifest = legacyDirectory.appendingPathComponent("store-manifest.json")
        let corruptManifest = Data("{not-valid-json".utf8)
        try corruptManifest.write(to: manifest)

        XCTAssertThrowsError(
            try database.deleteStore(
                identity: identity,
                legacyOwnerProof: identity
            )
        ) { error in
            guard case FitnessDatabaseError.unverifiedLegacyStore = error else {
                return XCTFail("Expected an unverified legacy store, received \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: manifest), corruptManifest)
        XCTAssertEqual(try Data(contentsOf: legacyStore), storeBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDirectory.path))
    }

    func testBackupManifestRejectsChecksumTamperingOversizeAndSymbolicLink() throws {
        let identity = "family-a:user-a"
        let store = root.appendingPathComponent("backup-owner/fitness.sqlite")
        let seed = makeDatabase(through: 1)
        try seed.activateForTesting(identity: identity, storeURL: store)
        try seed.write { db in
            try db.execute(sql: "INSERT INTO durable_values(id,value) VALUES (1,'preserved')")
        }
        seed.suspend()

        let upgraded = makeDatabase(through: 2)
        try upgraded.activateForTesting(identity: identity, storeURL: store)
        upgraded.suspend()
        let valid = try upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store)
        let backup = try XCTUnwrap(valid.first)
        let manifest = backup.url.deletingLastPathComponent().appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifest)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        object["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifest, options: .atomic)
        XCTAssertTrue(
            try upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store).isEmpty
        )

        try Data(
            repeating: 0x20,
            count: FitnessDatabase.maximumManifestByteCount + 1
        ).write(to: manifest, options: .atomic)
        XCTAssertTrue(
            try upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store).isEmpty
        )

        let target = root.appendingPathComponent("outside-valid-backup-manifest.json")
        try original.write(to: target, options: .atomic)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: target)
        XCTAssertTrue(
            try upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store).isEmpty
        )
    }

    func testBackupOwnershipRequiresCanonicalRealDirectoryWithExactChildren() throws {
        let identity = "family-a:user-a"
        let store = root.appendingPathComponent("exact-backup-owner/fitness.sqlite")
        let seed = makeDatabase(through: 1)
        try seed.activateForTesting(identity: identity, storeURL: store)
        seed.suspend()

        let upgraded = makeDatabase(through: 2)
        try upgraded.activateForTesting(identity: identity, storeURL: store)
        upgraded.suspend()
        let validRecord = try XCTUnwrap(
            upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store).first
        )
        let validDirectory = validRecord.url.deletingLastPathComponent()
        let backupsDirectory = validDirectory.deletingLastPathComponent()

        let nearMiss = backupsDirectory.appendingPathComponent(
            "\(Int64.max)-\(UUID().uuidString.lowercased()).backup-copy",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: validDirectory, to: nearMiss)
        let symbolicLink = backupsDirectory.appendingPathComponent(
            "\(Int64.max)-\(UUID().uuidString.lowercased()).backup",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: validDirectory
        )

        XCTAssertEqual(
            try upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store),
            [validRecord]
        )

        let unexpectedChild = validDirectory.appendingPathComponent("provider-metadata.json")
        try Data("{}".utf8).write(to: unexpectedChild)
        XCTAssertTrue(
            try upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store).isEmpty
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: validDirectory.path))

        try FileManager.default.removeItem(at: unexpectedChild)
        XCTAssertEqual(
            try upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store),
            [validRecord]
        )
    }

    func testBackupVerificationCandidatesAreBoundedToDeterministicNewestSet() throws {
        let identity = "family-a:user-a"
        let store = root.appendingPathComponent("bounded-backup-owner/fitness.sqlite")
        let seed = makeDatabase(through: 1)
        try seed.activateForTesting(identity: identity, storeURL: store)
        seed.suspend()

        let upgraded = makeDatabase(through: 2)
        try upgraded.activateForTesting(identity: identity, storeURL: store)
        upgraded.suspend()
        let validDirectory = try XCTUnwrap(
            upgraded.verifiedRecoveryBackups(identity: identity, storeURL: store).first
        ).url.deletingLastPathComponent()
        let backupsDirectory = validDirectory.deletingLastPathComponent()
        let timestampBase: Int64 = 8_000_000_000_000_000_000
        var copies: [(timestamp: Int64, url: URL)] = []
        for offset in 0..<70 {
            let timestamp = timestampBase + Int64(offset)
            let copy = backupsDirectory.appendingPathComponent(
                "\(timestamp)-\(UUID().uuidString.lowercased()).backup",
                isDirectory: true
            )
            try FileManager.default.copyItem(at: validDirectory, to: copy)
            copies.append((timestamp, copy))
        }

        let records = try upgraded.verifiedRecoveryBackups(
            identity: identity,
            storeURL: store
        )
        XCTAssertEqual(records.count, FitnessDatabase.maximumBackupVerificationCandidates)
        let returnedNames = Set(
            records.map { $0.url.deletingLastPathComponent().lastPathComponent }
        )
        let expectedNames = Set(
            copies.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            .prefix(FitnessDatabase.maximumBackupVerificationCandidates)
            .map { $0.url.lastPathComponent }
        )
        XCTAssertEqual(returnedNames, expectedNames)
        XCTAssertFalse(returnedNames.contains(validDirectory.lastPathComponent))
    }

    private func makeDatabase(through version: Int) -> FitnessDatabase {
        FitnessDatabase(
            rootDirectory: root,
            migrationIdentifiers: (1...version).map { String(format: "%03d", $0) },
            migratorFactory: { Self.migrator(through: version) }
        )
    }

    private func storeManifestURL(identity: String) -> URL {
        root.appendingPathComponent(
            FitnessDatabase.identityDirectoryName(identity), isDirectory: true
        ).appendingPathComponent("store-manifest.json")
    }

    private static func migrator(through version: Int) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        for number in 1...version {
            let identifier = String(format: "%03d", number)
            migrator.registerMigration(identifier) { db in
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
                    try db.execute(
                        sql: "CREATE TABLE migration_\(number) (id INTEGER PRIMARY KEY)"
                    )
                }
            }
        }
        return migrator
    }
}
