import Darwin
import Foundation
import XCTest

@testable import HausKlar

final class ShareExportStoreTests: XCTestCase {
    private final class ThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var observations: [Bool] = []

        func record() {
            lock.lock()
            observations.append(Thread.isMainThread)
            lock.unlock()
        }

        var allOffMain: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !observations.isEmpty && observations.allSatisfy { !$0 }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "share-export-store-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func entries(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
    }

    private func ownerDirectory(in root: URL) throws -> URL {
        try XCTUnwrap(entries(in: root).first { $0.lastPathComponent.hasPrefix("owner-") })
    }

    private func exactArtifactCount(in ownerDirectory: URL) throws -> Int {
        try entries(in: ownerDirectory).filter {
            let name = $0.lastPathComponent
            if name.hasPrefix(".stage-") {
                let id = String(name.dropFirst(".stage-".count))
                return id == id.lowercased() && UUID(uuidString: id) != nil
            }
            if name.hasSuffix(".export") {
                let id = String(name.dropLast(".export".count))
                return id == id.lowercased() && UUID(uuidString: id) != nil
            }
            return false
        }.count
    }

    func testExactItemLimitAndRetainReleaseLifetime() async throws {
        let root = try temporaryDirectory().appendingPathComponent("exports", isDirectory: true)
        var limits = ShareExportStore.Limits()
        limits.maximumItemBytes = 16
        limits.maximumTotalBytes = 16
        limits.maximumItems = 1
        let store = ShareExportStore(rootDirectory: root, limits: limits)
        let lease = try await store.activate(identity: "family-a:user-a")

        let item = try await store.publishData(
            Data(repeating: 0x5A, count: 16),
            filename: "exact.bin",
            lease: lease
        )
        XCTAssertEqual(try Data(contentsOf: item.url), Data(repeating: 0x5A, count: 16))
        do {
            _ = try await store.publishData(
                Data("blocked".utf8),
                filename: "blocked.txt",
                lease: lease
            )
            XCTFail("A held item must count against both item and aggregate quotas")
        } catch ShareExportStoreError.quotaExceeded {
            // Expected.
        }
        try await store.retain(item)
        try await store.release(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        try await store.release(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))

        do {
            _ = try await store.publishData(
                Data(repeating: 0x5A, count: 17),
                filename: "oversized.bin",
                lease: lease
            )
            XCTFail("One byte above the item limit must fail")
        } catch ShareExportStoreError.fileTooLarge {
            // Expected.
        }
        let reservedNameItem = try await store.publishData(
            Data("manifest".utf8),
            filename: "manifest.json",
            lease: lease
        )
        XCTAssertNotEqual(reservedNameItem.url.lastPathComponent.lowercased(), "manifest.json")
        XCTAssertEqual(try Data(contentsOf: reservedNameItem.url), Data("manifest".utf8))
        try await store.securePurgeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        do {
            _ = try await store.currentLease()
            XCTFail("A secure account purge must invalidate the owner lease")
        } catch ShareExportStoreError.notActive {
            // Expected.
        }
    }

    func testCrossVolumeFallbackStreamsOffMainAndRemovesOnlyTheAdoptedSource() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("exports", isDirectory: true)
        let transfer = directory.appendingPathComponent("transfer", isDirectory: true)
        try FileManager.default.createDirectory(at: transfer, withIntermediateDirectories: true)
        let source = transfer.appendingPathComponent("original.jpg")
        let sibling = transfer.appendingPathComponent("keep.txt")
        let payload = Data(repeating: 0x4A, count: 2 * 1_024 * 1_024)
        try payload.write(to: source)
        try Data("keep".utf8).write(to: sibling)
        let recorder = ThreadRecorder()
        let store = ShareExportStore(
            rootDirectory: root,
            moveOperation: { _, _ in throw POSIXError(.EXDEV) },
            ioProbe: { recorder.record() }
        )
        let lease = try await store.activate(identity: "family-a:user-a")

        let item = try await store.adoptDownloadedFile(
            source,
            filename: "original.jpg",
            expectedByteCount: payload.count,
            maximumBytes: payload.count,
            lease: lease
        )

        XCTAssertEqual(try Data(contentsOf: item.url), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(recorder.allOffMain)
        try await store.release(item)
    }

    func testSymlinkAndOversizedAdoptionAreRejectedWithoutProviderMutation() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("exports", isDirectory: true)
        let target = directory.appendingPathComponent("target.jpg")
        let symlink = directory.appendingPathComponent("link.jpg")
        try Data(repeating: 0x33, count: 32).write(to: target)
        let targetBytes = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let oversized = directory.appendingPathComponent("oversized.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 65)
        try handle.close()
        var limits = ShareExportStore.Limits()
        limits.maximumItemBytes = 64
        let store = ShareExportStore(rootDirectory: root, limits: limits)
        let lease = try await store.activate(identity: "family-a:user-a")

        do {
            _ = try await store.adoptDownloadedFile(
                symlink,
                filename: "link.jpg",
                maximumBytes: 64,
                lease: lease
            )
            XCTFail("A provider symlink must not be followed")
        } catch ShareExportStoreError.invalidFile {
            // Expected.
        }
        do {
            _ = try await store.adoptDownloadedFile(
                oversized,
                filename: "oversized.jpg",
                maximumBytes: 64,
                lease: lease
            )
            XCTFail("A source above the exact adoption bound must fail")
        } catch ShareExportStoreError.fileTooLarge {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: oversized.path))
        XCTAssertEqual(try exactArtifactCount(in: ownerDirectory(in: root)), 0)
    }

    func testCancelledCrossVolumeFallbackKeepsSourceAndRemovesPartialStage() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("exports", isDirectory: true)
        let source = directory.appendingPathComponent("source.jpg")
        try Data(repeating: 0x4A, count: 1_024 * 1_024).write(to: source)
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let store = ShareExportStore(
            rootDirectory: root,
            moveOperation: { _, _ in
                started.signal()
                proceed.wait()
                throw POSIXError(.EXDEV)
            }
        )
        let lease = try await store.activate(identity: "family-a:user-a")
        let task = Task {
            try await store.adoptDownloadedFile(
                source,
                filename: "source.jpg",
                maximumBytes: 1_024 * 1_024,
                lease: lease
            )
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        task.cancel()
        proceed.signal()

        do {
            _ = try await task.value
            XCTFail("Cancellation must prevent cross-volume publication")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try exactArtifactCount(in: ownerDirectory(in: root)), 0)
    }

    func testRestartedOwnerActivationPurgesOtherExactOwnersButNeverSymlinkTargetsOrNearMisses() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("exports", isDirectory: true)
        let firstStore = ShareExportStore(rootDirectory: root)
        let firstLease = try await firstStore.activate(identity: "family-a:user-a")
        let firstItem = try await firstStore.publishData(
            Data("private-a".utf8),
            filename: "a.txt",
            lease: firstLease
        )
        let firstOwner = firstItem.url.deletingLastPathComponent().deletingLastPathComponent()
        let nearMiss = root.appendingPathComponent("owner-not-an-exact-hash", isDirectory: true)
        try FileManager.default.createDirectory(at: nearMiss, withIntermediateDirectories: true)
        let nearMissMarker = nearMiss.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: nearMissMarker)
        let external = directory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalMarker = external.appendingPathComponent("private.txt")
        try Data("external".utf8).write(to: externalMarker)
        let foreignOwnerLink = root.appendingPathComponent("owner-\(String(repeating: "a", count: 64))")
        try FileManager.default.createSymbolicLink(at: foreignOwnerLink, withDestinationURL: external)

        let restartedStore = ShareExportStore(rootDirectory: root)
        let secondLease = try await restartedStore.activate(identity: "family-b:user-b")

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstOwner.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreignOwnerLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMissMarker.path))
        do {
            try await firstStore.retain(firstItem)
            XCTFail("The first actor's stale on-disk item must no longer validate")
        } catch {
            // The restarted owner synchronously removed it.
        }
        let secondItem = try await restartedStore.publishData(
            Data("private-b".utf8),
            filename: "b.txt",
            lease: secondLease
        )
        XCTAssertEqual(try Data(contentsOf: secondItem.url), Data("private-b".utf8))
        try await restartedStore.release(secondItem)
    }

    func testAgedCrashReconciliationIsEffectBoundedAndPreservesNearMissAndSymlinkTarget() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("exports", isDirectory: true)
        let crashedStore = ShareExportStore(rootDirectory: root)
        let crashedLease = try await crashedStore.activate(identity: "family-a:user-a")
        _ = try await crashedStore.publishData(
            Data("crash-item".utf8),
            filename: "crash.txt",
            lease: crashedLease
        )
        let owner = try ownerDirectory(in: root)
        let now = Date()
        let staleStage = owner.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staleStage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: staleStage.path
        )
        let nearMiss = owner.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased()).partial",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: nearMiss, withIntermediateDirectories: true)
        let external = directory.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalMarker = external.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: externalMarker)
        let stageSymlink = owner.appendingPathComponent(
            ".stage-\(UUID().uuidString.lowercased())"
        )
        try FileManager.default.createSymbolicLink(at: stageSymlink, withDestinationURL: external)

        var limits = ShareExportStore.Limits()
        limits.maximumAge = 60
        limits.stagingMaximumAge = 60
        limits.maximumReconciliationEffects = 1
        let restartedStore = ShareExportStore(rootDirectory: root, limits: limits)
        let restartedLease = try await restartedStore.activate(
            identity: "family-a:user-a",
            now: now.addingTimeInterval(7_200)
        )

        XCTAssertEqual(try exactArtifactCount(in: owner), 2)
        let report = try await restartedStore.reconcile(
            lease: restartedLease,
            now: now.addingTimeInterval(7_200)
        )
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(try exactArtifactCount(in: owner), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stageSymlink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalMarker.path))
    }

    func testReconciliationInspectionAndEffectsStopAtConfiguredBudgets() async throws {
        let root = try temporaryDirectory().appendingPathComponent("exports", isDirectory: true)
        var limits = ShareExportStore.Limits()
        limits.stagingMaximumAge = 60
        limits.maximumReconciliationCandidates = 1
        limits.maximumReconciliationEffects = 1
        let store = ShareExportStore(rootDirectory: root, limits: limits)
        let lease = try await store.activate(identity: "family-a:user-a")
        let owner = try ownerDirectory(in: root)
        let now = Date()
        for _ in 0..<2 {
            let stage = owner.appendingPathComponent(
                ".stage-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-7_200)],
                ofItemAtPath: stage.path
            )
        }

        let report = try await store.reconcile(
            lease: lease,
            now: now.addingTimeInterval(7_200)
        )

        XCTAssertEqual(report.inspectedCandidateCount, 1)
        XCTAssertTrue(report.candidateLimitReached)
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertEqual(try exactArtifactCount(in: owner), 1)
    }

    func testCancellationCleansGeneratedStageAndWriterRunsOffMain() async throws {
        let root = try temporaryDirectory().appendingPathComponent("exports", isDirectory: true)
        let recorder = ThreadRecorder()
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let store = ShareExportStore(
            rootDirectory: root,
            ioProbe: { recorder.record() }
        )
        let lease = try await store.activate(identity: "family-a:user-a")

        let task = Task {
            try await store.publishGeneratedFile(
                filename: "cancelled.pdf",
                maximumBytes: 1_024,
                lease: lease
            ) { destination in
                recorder.record()
                started.signal()
                proceed.wait()
                try Task.checkCancellation()
                try Data("pdf".utf8).write(to: destination)
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        task.cancel()
        proceed.signal()

        do {
            _ = try await task.value
            XCTFail("A cancelled generated export must never publish")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertTrue(recorder.allOffMain)
        XCTAssertEqual(try exactArtifactCount(in: ownerDirectory(in: root)), 0)
    }

    func testOwnerSwitchWhileWriterIsSuspendedInvalidatesPublicationAndCleansOldRoot() async throws {
        let root = try temporaryDirectory().appendingPathComponent("exports", isDirectory: true)
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let store = ShareExportStore(rootDirectory: root)
        let firstLease = try await store.activate(identity: "family-a:user-a")
        let task = Task {
            try await store.publishGeneratedFile(
                filename: "late.pdf",
                maximumBytes: 1_024,
                lease: firstLease
            ) { destination in
                started.signal()
                proceed.wait()
                try Data("late".utf8).write(to: destination)
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let secondLease = try await store.activate(identity: "family-b:user-b")
        proceed.signal()

        do {
            _ = try await task.value
            XCTFail("The previous owner must not publish after an identity switch")
        } catch {
            // A stale lease or removed staging path is expected.
        }

        let secondItem = try await store.publishData(
            Data("current".utf8),
            filename: "current.txt",
            lease: secondLease
        )
        XCTAssertEqual(try Data(contentsOf: secondItem.url), Data("current".utf8))
        XCTAssertEqual(
            try entries(in: root).filter { $0.lastPathComponent.hasPrefix("owner-") }.count,
            1
        )
        try await store.release(secondItem)
    }
}
