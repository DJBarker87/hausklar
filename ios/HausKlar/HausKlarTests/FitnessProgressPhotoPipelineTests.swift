import Foundation
import GRDB
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HausKlar

final class FitnessProgressPhotoPipelineTests: XCTestCase {
    private var directory: URL!
    private var storeURL: URL!
    private var database: FitnessDatabase!
    private var repository: FitnessHealthRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FitnessProgressPhotoPipelineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("owner/fitness.sqlite")
        database = FitnessDatabase()
        try database.activateForTesting(identity: "family-a:user-a", storeURL: storeURL)
        repository = FitnessHealthRepository(database: database, clientId: "test-client")
    }

    override func tearDownWithError() throws {
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testTransferredProviderRemainsReadOnlyAndOwnedFilesAreCleaned() throws {
        let seed = try makeArtifact(rootName: "seed")
        defer { FitnessProgressPhotoPreparation.removeArtifact(seed) }
        let providerDirectory = directory.appendingPathComponent("provider", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerDirectory,
            withIntermediateDirectories: true
        )
        let provider = providerDirectory.appendingPathComponent("selected.jpg")
        try FileManager.default.copyItem(at: seed.fileURL, to: provider)
        let originalBytes = try Data(contentsOf: provider)

        let staged = try PhotoUploadPrep.stageTransferredFile(
            at: provider,
            root: directory.appendingPathComponent("transfer-staging", isDirectory: true)
        )
        let artifact = try FitnessProgressPhotoPreparation.prepareTransferredFile(
            staged,
            declaredTypeIdentifiers: [UTType.jpeg.identifier],
            root: directory.appendingPathComponent("prepared", isDirectory: true)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
        XCTAssertEqual(try Data(contentsOf: provider), originalBytes)
        XCTAssertNotEqual(staged.fileURL.standardizedFileURL, provider.standardizedFileURL)
        XCTAssertNotEqual(artifact.fileURL.standardizedFileURL, provider.standardizedFileURL)

        PhotoUploadPrep.removeStagedFile(staged)
        FitnessProgressPhotoPreparation.removeArtifact(artifact)

        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
        XCTAssertEqual(try Data(contentsOf: provider), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.directoryURL.path))
    }

    func testCancelledTransferCreatesNoOwnedCopyAndPreservesProvider() async throws {
        let seed = try makeArtifact(rootName: "cancel-seed")
        defer { FitnessProgressPhotoPreparation.removeArtifact(seed) }
        let provider = directory.appendingPathComponent("cancel-provider.jpg")
        try FileManager.default.copyItem(at: seed.fileURL, to: provider)
        let stagingRoot = directory.appendingPathComponent("cancel-staging", isDirectory: true)

        let task = Task.detached { () throws -> PhotoUploadPrep.StagedFile in
            while !Task.isCancelled { await Task.yield() }
            return try PhotoUploadPrep.stageTransferredFile(at: provider, root: stagingRoot)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled import must not retain a staged file")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
        let stagedEntries = try? FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(stagedEntries ?? [], [])
    }

    func testSymlinkAndOversizedSourcesAreRejectedBeforeIdentityStorage() async throws {
        let target = try makeArtifact(rootName: "symlink-target")
        defer { FitnessProgressPhotoPreparation.removeArtifact(target) }
        let symlink = directory.appendingPathComponent("provider-link.jpg")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target.fileURL)
        XCTAssertThrowsError(
            try PhotoUploadPrep.stageTransferredFile(
                at: symlink,
                root: directory.appendingPathComponent("symlink-staging", isDirectory: true)
            )
        )

        let oversized = directory.appendingPathComponent("oversized.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(
            atOffset: UInt64(FitnessProgressPhotoPreparation.maximumJPEGBytes + 1)
        )
        try handle.close()
        do {
            _ = try await repository.createProgressPhoto(
                jpegFileURL: oversized, capturedAt: Date(), pose: .front,
                bodyWeightKg: nil, phaseId: nil, notes: nil, clientId: "test-client"
            )
            XCTFail("An oversized source must be rejected")
        } catch {
            XCTAssertTrue(error is PhotoUploadPrepError)
        }

        let databaseCounts = try database.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_progress_photos") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_private_file_uploads") ?? 0
            )
        }
        XCTAssertEqual(databaseCounts.0, 0)
        XCTAssertEqual(databaseCounts.1, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.fileURL.path))
    }

    func testDatabaseFailureRetainsOneReconciliableOrphanAcrossRestart() async throws {
        let artifact = try makeArtifact(rootName: "database-failure")
        defer { FitnessProgressPhotoPreparation.removeArtifact(artifact) }
        try database.write { db in
            try db.execute(
                sql: """
                    CREATE TRIGGER reject_progress_photo BEFORE INSERT ON fitness_progress_photos
                    BEGIN SELECT RAISE(ABORT,'forced progress photo failure'); END;
                    """)
        }

        do {
            _ = try await repository.createProgressPhoto(
                jpegFileURL: artifact.fileURL, capturedAt: Date(), pose: .sideLeft,
                bodyWeightKg: nil, phaseId: nil, notes: nil, clientId: "test-client"
            )
            XCTFail("The injected database failure must escape")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))
        }
        let now = Date()
        let orphan = try XCTUnwrap(progressPhotoOwnedFiles().first)
        XCTAssertNoThrow(
            try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(
                at: orphan
            )
        )
        let freshRemovalCount = try await repository.reconcileProgressPhotoFiles(
            now: now,
            minimumAge: 3_600
        )
        XCTAssertEqual(freshRemovalCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        database.suspend()
        try database.activateForTesting(identity: "family-a:user-a", storeURL: storeURL)
        let restartedRepository = FitnessHealthRepository(
            database: database,
            clientId: "test-client"
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: orphan.path
        )
        let agedRemovalCount = try await restartedRepository.reconcileProgressPhotoFiles(
            now: now,
            minimumAge: 3_600
        )
        XCTAssertEqual(agedRemovalCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testIdentityReconciliationCountsOnlyExactOldOwnedOrphans() async throws {
        let artifact = try makeArtifact(rootName: "private-reconciliation-source")
        defer { FitnessProgressPhotoPreparation.removeArtifact(artifact) }
        let pending = try await repository.createProgressPhoto(
            jpegFileURL: artifact.fileURL, capturedAt: Date(), pose: .front,
            bodyWeightKg: nil, phaseId: nil, notes: nil, clientId: "test-client"
        )
        let referenced = try await repository.localOriginalURL(assetId: pending.id)
        let photoDirectory = referenced.deletingLastPathComponent()
        let now = Date()
        let oldDate = now.addingTimeInterval(-7_200)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: referenced.path
        )

        let staleOrphans = try (0..<2).map { _ in
            let url = photoDirectory.appendingPathComponent(
                "\(UUID().uuidString.lowercased()).jpg"
            )
            try FileManager.default.copyItem(at: artifact.fileURL, to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: url.path
            )
            return url
        }
        let fresh = photoDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).jpg"
        )
        try FileManager.default.copyItem(at: artifact.fileURL, to: fresh)
        let nearMiss = photoDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).jpeg"
        )
        try FileManager.default.copyItem(at: artifact.fileURL, to: nearMiss)
        let providerTarget = directory.appendingPathComponent("private-provider.jpg")
        try FileManager.default.copyItem(at: artifact.fileURL, to: providerTarget)
        let providerBytes = try Data(contentsOf: providerTarget)
        let symbolicLink = photoDirectory.appendingPathComponent(
            "\(UUID().uuidString.lowercased()).jpg"
        )
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: providerTarget
        )
        for index in 0..<300 {
            let unrelated = photoDirectory.appendingPathComponent("unrelated-\(index).txt")
            XCTAssertTrue(FileManager.default.createFile(atPath: unrelated.path, contents: nil))
        }

        let firstRemovalCount = try await repository.reconcileProgressPhotoFiles(
            now: now,
            minimumAge: 3_600,
            maximumCandidates: 1,
            maximumRemovals: 1
        )
        XCTAssertEqual(firstRemovalCount, 1)
        XCTAssertEqual(
            staleOrphans.filter { FileManager.default.fileExists(atPath: $0.path) }.count,
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertEqual(try Data(contentsOf: providerTarget), providerBytes)

        let remainingRemovalCount = try await repository.reconcileProgressPhotoFiles(
            now: now,
            minimumAge: 3_600,
            maximumCandidates: 32,
            maximumRemovals: 32
        )
        XCTAssertEqual(remainingRemovalCount, 1)
        XCTAssertTrue(
            staleOrphans.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            })
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertEqual(try Data(contentsOf: providerTarget), providerBytes)
    }

    func testStoredByteCountMatchesVerifiedFileAndSurvivesAccountSwitch() async throws {
        let artifact = try makeArtifact(rootName: "identity")
        defer { FitnessProgressPhotoPreparation.removeArtifact(artifact) }
        let pending = try await repository.createProgressPhoto(
            jpegFileURL: artifact.fileURL, capturedAt: Date(), pose: .back,
            bodyWeightKg: 72.5, phaseId: nil, notes: nil, clientId: "test-client"
        )
        let ownerURL = try await repository.localOriginalURL(assetId: pending.id)
        let storedCount = try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT byte_count FROM fitness_private_file_uploads WHERE asset_id=?",
                arguments: [pending.id]
            )
        }
        XCTAssertEqual(storedCount, pending.byteCount)
        XCTAssertEqual(
            storedCount,
            try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(at: ownerURL)
        )

        database.suspend()
        try database.activateForTesting(
            identity: "family-a:user-b",
            storeURL: directory.appendingPathComponent("other/fitness.sqlite")
        )
        let otherPending = try await repository.pendingProgressPhotos()
        XCTAssertTrue(otherPending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerURL.path))

        database.suspend()
        try database.activateForTesting(identity: "family-a:user-a", storeURL: storeURL)
        let restoredPending = try await repository.pendingProgressPhotos()
        let restoredURL = try await repository.localOriginalURL(assetId: pending.id)
        XCTAssertEqual(restoredPending.map(\.id), [pending.id])
        XCTAssertEqual(
            restoredURL.standardizedFileURL,
            ownerURL.standardizedFileURL
        )
    }

    func testAccountSwitchDuringCopyCannotPublishOrCommitIntoReplacementOwner() async throws {
        let artifact = try makeArtifact(rootName: "copy-account-switch")
        defer { FitnessProgressPhotoPreparation.removeArtifact(artifact) }
        let replacementStore = directory.appendingPathComponent(
            "replacement/fitness.sqlite"
        )
        let switchingDatabase = try XCTUnwrap(database)

        do {
            _ = try await repository.createProgressPhoto(
                jpegFileURL: artifact.fileURL, capturedAt: Date(), pose: .front,
                bodyWeightKg: nil, phaseId: nil, notes: nil, clientId: "test-client",
                onChunkCopied: { _ in
                    try? switchingDatabase.activateForTesting(
                        identity: "family-a:user-b",
                        storeURL: replacementStore
                    )
                }
            )
            XCTFail("A progress photo cannot cross an account switch")
        } catch {
            XCTAssertEqual(database.activeIdentity, "family-a:user-b")
        }

        XCTAssertEqual(
            try database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_progress_photos") ?? -1
            }, 0)
        XCTAssertEqual(
            try database.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fitness_private_file_uploads") ?? -1
            }, 0)
        let originalFiles = progressPhotoOwnedFiles()
        XCTAssertEqual(originalFiles.count, 1)
        XCTAssertNoThrow(
            try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(
                at: try XCTUnwrap(originalFiles.first)
            )
        )
        let replacementDirectory = replacementStore.deletingLastPathComponent()
            .appendingPathComponent("PrivateRequired/ProgressPhotos", isDirectory: true)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: replacementDirectory.path))?
                .isEmpty ?? true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))
    }

    func testArtifactReconciliationRemovesOnlyOldOwnedShape() throws {
        let root = directory.appendingPathComponent("artifact-reconciliation", isDirectory: true)
        let old = try makeArtifact(root: root)
        let fresh = try makeArtifact(root: root)
        defer { FitnessProgressPhotoPreparation.removeArtifact(fresh) }
        let oldDate = Date(timeIntervalSinceNow: -7_200)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: old.fileURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: old.directoryURL.path
        )
        let outside = directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedEntry = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedEntry, withDestinationURL: outside)
        for index in 0..<300 {
            let unrelated = root.appendingPathComponent("unrelated-\(index).txt")
            XCTAssertTrue(FileManager.default.createFile(atPath: unrelated.path, contents: nil))
        }

        let removed = FitnessProgressPhotoPreparation.reconcileArtifacts(
            at: root,
            now: Date(),
            minimumAge: 3_600,
            maximumCandidates: 1,
            maximumRemovals: 1
        )

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let linkedValues = try linkedEntry.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: linkedEntry.path)
                || linkedValues.isSymbolicLink == true
        )
    }

    private func makeArtifact(rootName: String) throws -> FitnessProgressPhotoArtifact {
        try makeArtifact(root: directory.appendingPathComponent(rootName, isDirectory: true))
    }

    private func makeArtifact(root: URL) throws -> FitnessProgressPhotoArtifact {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).image {
            UIColor.systemIndigo.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        }
        return try FitnessProgressPhotoPreparation.prepareCameraImage(image, root: root)
    }

    private func progressPhotoOwnedFiles() -> [URL] {
        let photoDirectory = storeURL.deletingLastPathComponent().appendingPathComponent(
            "PrivateRequired/ProgressPhotos",
            isDirectory: true
        )
        guard
            let entries = FileManager.default.enumerator(
                at: photoDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
        else { return [] }
        var values: [URL] = []
        while let next = entries.nextObject() as? URL {
            if next.lastPathComponent.hasSuffix(".jpg") {
                values.append(next)
            }
        }
        return values
    }
}
