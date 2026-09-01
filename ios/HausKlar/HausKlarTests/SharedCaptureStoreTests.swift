import Foundation
import XCTest

@testable import HausKlar

final class SharedCaptureStoreTests: XCTestCase {
    private var containerURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedCaptureStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
        suiteName = "SharedCaptureStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        try? SharedCaptureStore.purge(
            defaults: defaults,
            containerURL: containerURL,
            fileManager: .default
        )
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: containerURL)
        defaults = nil
        containerURL = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func testConcurrentProducersAndConsumersNeverLoseOrDuplicateItems() throws {
        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("family:user", context: context)
        let resultLock = NSLock()
        var producerErrors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do {
                try SharedCaptureStore.enqueueText(
                    "item \(index)",
                    ownerIdentity: "family:user",
                    context: context,
                    now: Date(timeIntervalSince1970: TimeInterval(index + 1))
                )
            } catch {
                resultLock.withLock { producerErrors.append(error) }
            }
        }
        XCTAssertTrue(producerErrors.isEmpty, "Producer failures: \(producerErrors)")

        var consumedIDs: [String] = []
        var consumerErrors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            while true {
                do {
                    guard
                        let claim = try SharedCaptureStore.claimNext(
                            for: "family:user",
                            context: context
                        )
                    else { return }
                    resultLock.withLock { consumedIDs.append(claim.payload.id) }
                    try SharedCaptureStore.acknowledge(claim, context: context)
                } catch {
                    resultLock.withLock { consumerErrors.append(error) }
                    return
                }
            }
        }

        XCTAssertTrue(consumerErrors.isEmpty, "Consumer failures: \(consumerErrors)")
        XCTAssertEqual(consumedIDs.count, 12)
        XCTAssertEqual(Set(consumedIDs).count, 12)
        XCTAssertTrue(try SharedCaptureStore.recoveryItems(context: context).isEmpty)
    }

    func testClaimSurvivesCrashUntilExpiryThenRecoversOldestItem() throws {
        var limits = SharedCaptureStore.Limits()
        limits.claimLifetime = 10
        let context = makeContext(limits: limits)
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let start = Date(timeIntervalSince1970: 1_000)
        let id = try SharedCaptureStore.enqueueText(
            "keep me",
            ownerIdentity: "A",
            context: context,
            now: start
        )
        let abandoned = try XCTUnwrap(
            SharedCaptureStore.claimNext(for: "A", context: context, now: start)
        )

        XCTAssertNil(try SharedCaptureStore.claimNext(for: "A", context: context, now: start.addingTimeInterval(9)))
        let recovered = try XCTUnwrap(
            SharedCaptureStore.claimNext(for: "A", context: context, now: start.addingTimeInterval(11))
        )
        XCTAssertEqual(recovered.payload.id, id)
        XCTAssertNotEqual(recovered.leaseID, abandoned.leaseID)
        XCTAssertThrowsError(try SharedCaptureStore.acknowledge(abandoned, context: context)) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .staleClaim)
        }
        try SharedCaptureStore.acknowledge(recovered, context: context)
    }

    func testFractionalClaimExpiryMatchesThePersistedLease() throws {
        var limits = SharedCaptureStore.Limits()
        limits.claimLifetime = 0.5
        let context = makeContext(limits: limits)
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let start = Date(timeIntervalSince1970: 1_800_000_000.125_4)
        _ = try SharedCaptureStore.enqueueText(
            "fractional lease",
            ownerIdentity: "A",
            context: context,
            now: start
        )

        let claim = try XCTUnwrap(
            SharedCaptureStore.claimNext(for: "A", context: context, now: start)
        )
        XCTAssertEqual(
            claim.expiresAt.timeIntervalSince1970,
            1_800_000_000.625,
            accuracy: 0.000_001
        )
        XCTAssertNil(
            try SharedCaptureStore.claimNext(
                for: "A",
                context: context,
                now: start.addingTimeInterval(0.499)
            )
        )
        let reclaimed = try XCTUnwrap(
            SharedCaptureStore.claimNext(
                for: "A",
                context: context,
                now: claim.expiresAt
            )
        )
        XCTAssertNotEqual(reclaimed.leaseID, claim.leaseID)
        try SharedCaptureStore.acknowledge(reclaimed, context: context)
    }

    func testNonFiniteDatesAndLifetimesFailClosedWithoutTrapping() throws {
        var invalidLimits = SharedCaptureStore.Limits()
        invalidLimits.claimLifetime = .infinity
        let invalidContext = makeContext(limits: invalidLimits)
        XCTAssertThrowsError(
            try SharedCaptureStore.setActiveIdentity("A", context: invalidContext)
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }

        var invalidTemporaryLimits = SharedCaptureStore.Limits()
        invalidTemporaryLimits.temporaryLifetime = 0
        XCTAssertThrowsError(
            try SharedCaptureStore.setActiveIdentity(
                "A",
                context: makeContext(limits: invalidTemporaryLimits)
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }

        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueText(
                "invalid date",
                ownerIdentity: "A",
                context: context,
                now: Date(timeIntervalSince1970: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueFileData(
                Data("invalid date".utf8),
                originalFilename: "invalid.txt",
                mediaType: "text/plain",
                ownerIdentity: "A",
                context: context,
                now: Date(timeIntervalSince1970: .nan)
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }
        XCTAssertThrowsError(
            try SharedCaptureStore.claimNext(
                for: "A",
                context: context,
                now: Date(timeIntervalSince1970: -.infinity)
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }
        XCTAssertThrowsError(
            try SharedCaptureStore.reconcile(
                context: context,
                now: Date(timeIntervalSince1970: .nan)
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }
        XCTAssertThrowsError(
            try SharedCaptureStore.recoveryItems(
                context: context,
                now: Date(timeIntervalSince1970: .infinity)
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }
        XCTAssertTrue(try SharedCaptureStore.recoveryItems(context: context).isEmpty)
    }

    func testReleaseImmediatelyReturnsItemWithANewLease() throws {
        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let id = try SharedCaptureStore.enqueueText("review", ownerIdentity: "A", context: context)
        let first = try XCTUnwrap(SharedCaptureStore.claimNext(for: "A", context: context))

        XCTAssertTrue(try SharedCaptureStore.release(first, context: context))
        let second = try XCTUnwrap(SharedCaptureStore.claimNext(for: "A", context: context))
        XCTAssertEqual(second.payload.id, id)
        XCTAssertNotEqual(second.leaseID, first.leaseID)
        try SharedCaptureStore.acknowledge(second, context: context)
    }

    func testAcknowledgementDeletesOnlyExactClaimAndItsAsset() throws {
        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let firstSource = try sourceFile(named: "first.pdf", bytes: Data("first".utf8))
        let secondSource = try sourceFile(named: "second.pdf", bytes: Data("second".utf8))
        let firstID = try SharedCaptureStore.enqueueFile(
            at: firstSource,
            mediaType: "application/pdf",
            ownerIdentity: "A",
            context: context,
            now: Date(timeIntervalSince1970: 1)
        )
        let secondID = try SharedCaptureStore.enqueueFile(
            at: secondSource,
            mediaType: "application/pdf",
            ownerIdentity: "A",
            context: context,
            now: Date(timeIntervalSince1970: 2)
        )
        let claim = try XCTUnwrap(SharedCaptureStore.claimNext(for: "A", context: context))
        let claimedAsset = try XCTUnwrap(claim.payload.filePath)

        XCTAssertEqual(claim.payload.id, firstID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimedAsset))
        try SharedCaptureStore.acknowledge(claim, context: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimedAsset))
        XCTAssertEqual(try SharedCaptureStore.recoveryItems(context: context).map(\.id), [secondID])
    }

    func testReconciliationRemovesStaleTemporaryInvalidAndOrphanAssets() throws {
        var limits = SharedCaptureStore.Limits()
        limits.temporaryLifetime = 10
        let context = makeContext(limits: limits)
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let now = Date(timeIntervalSince1970: 10_000)
        _ = try SharedCaptureStore.enqueueText("valid", ownerIdentity: "A", context: context, now: now)

        let root = containerURL.appendingPathComponent(SharedCaptureStore.directoryName, isDirectory: true)
        let temporary = root.appendingPathComponent(SharedCaptureStore.temporaryDirectoryName, isDirectory: true)
        let stale = temporary.appendingPathComponent(
            "stage-\(UUID().uuidString)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-20)],
            ofItemAtPath: stale.path
        )

        let ready = root.appendingPathComponent(SharedCaptureStore.readyDirectoryName, isDirectory: true)
        let validDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: ready, includingPropertiesForKeys: nil).first
        )
        let orphan = validDirectory.appendingPathComponent("orphan.bin")
        try Data("orphan".utf8).write(to: orphan)
        let invalid = ready.appendingPathComponent(
            String(
                format: "%016lld-%@.item",
                Int64(now.timeIntervalSince1970 * 1_000),
                UUID().uuidString.lowercased()
            ),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: invalid.appendingPathComponent("metadata.json"))
        let unrelatedReady = ready.appendingPathComponent("provider-notes.item", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedReady, withIntermediateDirectories: true)

        let result = try SharedCaptureStore.reconcile(context: context, now: now)
        XCTAssertEqual(result.removedTemporaryItems, 1)
        XCTAssertEqual(result.removedInvalidItems, 1)
        XCTAssertEqual(result.removedOrphanAssets, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedReady.path))
        XCTAssertEqual(try SharedCaptureStore.recoveryItems(context: context).count, 1)
    }

    func testReconciliationBudgetsStaleStagesAndSkipsSymlinkDirectories() throws {
        var limits = SharedCaptureStore.Limits()
        limits.temporaryLifetime = 10
        limits.maximumReconciliationCandidates = 3
        limits.maximumReconciliationMutations = 2
        let context = makeContext(limits: limits)
        let now = Date()
        _ = try SharedCaptureStore.reconcile(context: context, now: now)
        let temporary =
            containerURL
            .appendingPathComponent(SharedCaptureStore.directoryName, isDirectory: true)
            .appendingPathComponent(SharedCaptureStore.temporaryDirectoryName, isDirectory: true)
        let stale = (0..<5).map { _ in
            temporary.appendingPathComponent(
                "stage-\(UUID().uuidString)-\(UUID().uuidString.lowercased())",
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
        let providerTarget = containerURL.appendingPathComponent(
            "provider-owned", isDirectory: true
        )
        try FileManager.default.createDirectory(at: providerTarget, withIntermediateDirectories: true)
        let symbolicLink = temporary.appendingPathComponent(
            "stage-\(UUID().uuidString)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: providerTarget)
        let unrelatedStage = temporary.appendingPathComponent(
            "stage-provider-data-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unrelatedStage, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-20)],
            ofItemAtPath: unrelatedStage.path
        )

        XCTAssertEqual(
            try SharedCaptureStore.reconcile(context: context, now: now).removedTemporaryItems,
            2
        )
        XCTAssertEqual(stale.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 3)
        XCTAssertEqual(
            try SharedCaptureStore.reconcile(context: context, now: now).removedTemporaryItems,
            2
        )
        XCTAssertEqual(stale.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
        XCTAssertEqual(
            try SharedCaptureStore.reconcile(context: context, now: now).removedTemporaryItems,
            1
        )
        XCTAssertTrue(stale.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: providerTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedStage.path))
    }

    func testReconciliationRemovesItemWhoseAssetIsDefinitelyMissing() throws {
        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let source = try sourceFile(named: "missing.pdf", bytes: Data("content".utf8))
        _ = try SharedCaptureStore.enqueueFile(
            at: source,
            mediaType: "application/pdf",
            context: context
        )
        let ready = containerURL
            .appendingPathComponent(SharedCaptureStore.directoryName, isDirectory: true)
            .appendingPathComponent(SharedCaptureStore.readyDirectoryName, isDirectory: true)
        let itemDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: ready,
                includingPropertiesForKeys: nil
            ).first
        )
        let asset = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: itemDirectory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.lastPathComponent.hasPrefix("asset.") })
        )
        try FileManager.default.removeItem(at: asset)

        let result = try SharedCaptureStore.reconcile(context: context)

        XCTAssertEqual(result.removedInvalidItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDirectory.path))
    }

    func testLockedAccountRetainsOwnerBindingAndDifferentAccountCannotClaim() throws {
        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        // Reauthentication lock deliberately leaves the App Group owner marker in
        // place, so extension shares made while locked remain bound to A.
        let id = try SharedCaptureStore.enqueueText("A private item", context: context)

        XCTAssertNil(try SharedCaptureStore.claimNext(for: "B", context: context))
        XCTAssertEqual(SharedCaptureStore.activeIdentity(context: context), "A")
        let recovery = try SharedCaptureStore.recoveryItems(context: context)
        XCTAssertEqual(
            recovery,
            [
                SharedCaptureRecoveryItem(
                    id: id,
                    ownerIdentity: "A",
                    createdAt: recovery[0].createdAt,
                    byteCount: "A private item".utf8.count,
                    state: .ready
                )
            ])
        let ownerClaim = try XCTUnwrap(SharedCaptureStore.claimNext(for: "A", context: context))
        try SharedCaptureStore.acknowledge(ownerClaim, context: context)
    }

    func testClaimRequiresCurrentDurableIdentityAndExplicitProducerCannotBypassIt() throws {
        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let id = try SharedCaptureStore.enqueueText("A private item", context: context)

        try SharedCaptureStore.setActiveIdentity("B", context: context)

        XCTAssertNil(try SharedCaptureStore.claimNext(for: "A", context: context))
        XCTAssertNil(try SharedCaptureStore.claimNext(for: "", context: context))
        XCTAssertNil(
            try SharedCaptureStore.claimNext(for: " B", context: context),
            "Malformed identities must never acquire consumer authority"
        )
        XCTAssertNil(
            try SharedCaptureStore.claimNext(for: "B", context: context),
            "The current account must not claim an item owned by the previous account"
        )
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueText(
                "must remain with A",
                ownerIdentity: "A",
                context: context
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .accountBoundaryChanged)
        }
        XCTAssertEqual(try SharedCaptureStore.recoveryItems(context: context).map(\.id), [id])

        try SharedCaptureStore.setActiveIdentity("A", context: context)
        let ownerClaim = try XCTUnwrap(SharedCaptureStore.claimNext(for: "A", context: context))
        XCTAssertEqual(ownerClaim.payload.id, id)
        try SharedCaptureStore.acknowledge(ownerClaim, context: context)
    }

    func testPurgeRemovesInboxLegacyAssetsMetadataAndActiveIdentity() throws {
        let context = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: context)
        _ = try SharedCaptureStore.enqueueText("private", context: context)
        let legacy = containerURL.appendingPathComponent(SharedCaptureStore.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("old.txt"))
        defaults.set(Data("[]".utf8), forKey: SharedCaptureStore.queueKey)

        try SharedCaptureStore.purge(
            defaults: defaults,
            containerURL: containerURL,
            fileManager: .default
        )

        XCTAssertNil(defaults.object(forKey: SharedCaptureStore.queueKey))
        XCTAssertNil(defaults.string(forKey: SharedCaptureStore.activeIdentityKey))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: containerURL.appendingPathComponent(SharedCaptureStore.directoryName).path
            ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testPurgeFailsClosedWhenSharedContainerIsUnavailable() throws {
        defaults.set("A", forKey: SharedCaptureStore.activeIdentityKey)
        defaults.set(Data("[]".utf8), forKey: SharedCaptureStore.queueKey)

        XCTAssertThrowsError(
            try SharedCaptureStore.purge(
                defaults: defaults,
                containerURL: nil,
                fileManager: .default
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .containerUnavailable)
        }

        XCTAssertEqual(defaults.string(forKey: SharedCaptureStore.activeIdentityKey), "A")
        XCTAssertNotNil(defaults.data(forKey: SharedCaptureStore.queueKey))
    }

    func testMalformedLegacyIdentityMirrorNeverBecomesDurableAuthority() throws {
        let context = makeContext()
        defaults.set(" A\n", forKey: SharedCaptureStore.activeIdentityKey)
        let boundary = containerURL.appendingPathComponent(".SharedCaptureInbox-v2.boundary")

        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueText("must remain unowned", context: context)
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .coordinationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: boundary.path))
        XCTAssertNil(SharedCaptureStore.activeIdentity(context: context))

        try SharedCaptureStore.clearActiveIdentity(context: context)
        XCTAssertNil(defaults.string(forKey: SharedCaptureStore.activeIdentityKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundary.path))
    }

    func testProducerResolvedBeforePurgeCannotPublishAfterPurgeCompletes() throws {
        let identityContext = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: identityContext)
        let boundaryResolved = DispatchSemaphore(value: 0)
        let allowStaging = DispatchSemaphore(value: 0)
        let producerContext = makeContext {
            boundaryResolved.signal()
            _ = allowStaging.wait(timeout: .now() + 5)
        }
        let completion = expectation(description: "stale producer completed")
        let resultLock = NSLock()
        var producerError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try SharedCaptureStore.enqueueText(
                    "must not cross purge",
                    context: producerContext
                )
            } catch {
                resultLock.withLock { producerError = error }
            }
            completion.fulfill()
        }

        guard boundaryResolved.wait(timeout: .now() + 5) == .success else {
            allowStaging.signal()
            XCTFail("Producer did not resolve its pre-purge boundary")
            return
        }
        let inbox = containerURL.appendingPathComponent(
            SharedCaptureStore.directoryName,
            isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.path))
        let temporary = inbox.appendingPathComponent(
            SharedCaptureStore.temporaryDirectoryName,
            isDirectory: true
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: temporary,
                includingPropertiesForKeys: nil
            ).count,
            1,
            "The producer must reserve its one exact stage before releasing coordination"
        )
        var releasedProducer = false
        defer {
            if !releasedProducer { allowStaging.signal() }
        }
        try SharedCaptureStore.purge(
            defaults: defaults,
            containerURL: containerURL,
            fileManager: .default
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))
        allowStaging.signal()
        releasedProducer = true
        wait(for: [completion], timeout: 5)

        XCTAssertEqual(
            resultLock.withLock { producerError as? SharedCaptureStoreError },
            .accountBoundaryChanged
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: inbox.path),
            "A stale producer must not recreate any purged staging path"
        )
        XCTAssertNil(SharedCaptureStore.activeIdentity(context: identityContext))
        XCTAssertTrue(try SharedCaptureStore.recoveryItems(context: identityContext).isEmpty)
    }

    func testProducerResolvedForPreviousIdentityCannotPublishAfterIdentitySwitch() throws {
        let identityContext = makeContext()
        try SharedCaptureStore.setActiveIdentity("A", context: identityContext)
        let boundaryResolved = DispatchSemaphore(value: 0)
        let allowStaging = DispatchSemaphore(value: 0)
        let producerContext = makeContext {
            boundaryResolved.signal()
            _ = allowStaging.wait(timeout: .now() + 5)
        }
        let completion = expectation(description: "previous-identity producer completed")
        let resultLock = NSLock()
        var producerError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try SharedCaptureStore.enqueueFileData(
                    Data("private to A".utf8),
                    originalFilename: "note.txt",
                    mediaType: "text/plain",
                    context: producerContext
                )
            } catch {
                resultLock.withLock { producerError = error }
            }
            completion.fulfill()
        }

        guard boundaryResolved.wait(timeout: .now() + 5) == .success else {
            allowStaging.signal()
            XCTFail("Producer did not resolve identity A")
            return
        }
        var releasedProducer = false
        defer {
            if !releasedProducer { allowStaging.signal() }
        }
        try SharedCaptureStore.setActiveIdentity("B", context: identityContext)
        allowStaging.signal()
        releasedProducer = true
        wait(for: [completion], timeout: 5)

        XCTAssertEqual(
            resultLock.withLock { producerError as? SharedCaptureStoreError },
            .accountBoundaryChanged
        )
        XCTAssertEqual(SharedCaptureStore.activeIdentity(context: identityContext), "B")
        XCTAssertTrue(try SharedCaptureStore.recoveryItems(context: identityContext).isEmpty)

        let newID = try SharedCaptureStore.enqueueText("belongs to B", context: identityContext)
        let claim = try XCTUnwrap(
            SharedCaptureStore.claimNext(for: "B", context: identityContext)
        )
        XCTAssertEqual(claim.payload.id, newID)
        XCTAssertEqual(claim.payload.ownerIdentity, "B")
        try SharedCaptureStore.acknowledge(claim, context: identityContext)
    }

    func testConcurrentReservationsConsumeItemAndByteQuotaBeforeFileCopy() throws {
        var limits = SharedCaptureStore.Limits()
        limits.maximumItems = 2
        limits.maximumTotalBytes = 6
        let identityContext = makeContext(limits: limits)
        try SharedCaptureStore.setActiveIdentity("A", context: identityContext)
        let reservationReady = DispatchSemaphore(value: 0)
        let allowFirstCopy = DispatchSemaphore(value: 0)
        let producerContext = makeContext(limits: limits) {
            reservationReady.signal()
            _ = allowFirstCopy.wait(timeout: .now() + 5)
        }
        let completion = expectation(description: "reserved producer completed")
        let resultLock = NSLock()
        var producerError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try SharedCaptureStore.enqueueFileData(
                    Data(repeating: 0x41, count: 4),
                    originalFilename: "first.txt",
                    mediaType: "text/plain",
                    context: producerContext
                )
            } catch {
                resultLock.withLock { producerError = error }
            }
            completion.fulfill()
        }

        guard reservationReady.wait(timeout: .now() + 5) == .success else {
            allowFirstCopy.signal()
            XCTFail("First producer did not reserve its quota")
            return
        }
        var releasedProducer = false
        defer {
            if !releasedProducer { allowFirstCopy.signal() }
        }
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueFileData(
                Data(repeating: 0x42, count: 3),
                originalFilename: "too-large-together.txt",
                mediaType: "text/plain",
                context: identityContext
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .inboxFull)
        }

        let temporary = containerURL
            .appendingPathComponent(SharedCaptureStore.directoryName, isDirectory: true)
            .appendingPathComponent(SharedCaptureStore.temporaryDirectoryName, isDirectory: true)
        let reservations = try FileManager.default.contentsOfDirectory(
            at: temporary,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(reservations.count, 1)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                at: try XCTUnwrap(reservations.first),
                includingPropertiesForKeys: nil
            ).contains(where: { $0.lastPathComponent.hasPrefix("asset.") }),
            "Quota rejection must happen before either provider file is copied"
        )

        _ = try SharedCaptureStore.enqueueText("x", context: identityContext)
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueText("y", context: identityContext)
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .inboxFull)
        }

        allowFirstCopy.signal()
        releasedProducer = true
        wait(for: [completion], timeout: 5)
        XCTAssertNil(resultLock.withLock { producerError })
        XCTAssertEqual(try SharedCaptureStore.recoveryItems(context: identityContext).count, 2)
    }

    func testFutureDatedPublisherCannotReapAnotherLiveReservation() throws {
        var limits = SharedCaptureStore.Limits()
        limits.temporaryLifetime = 1
        let identityContext = makeContext(limits: limits)
        try SharedCaptureStore.setActiveIdentity("A", context: identityContext)
        let reservationReady = DispatchSemaphore(value: 0)
        let allowFirstCopy = DispatchSemaphore(value: 0)
        let producerContext = makeContext(limits: limits) {
            reservationReady.signal()
            _ = allowFirstCopy.wait(timeout: .now() + 5)
        }
        let completion = expectation(description: "live producer completed")
        let resultLock = NSLock()
        var producerError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try SharedCaptureStore.enqueueFileData(
                    Data("live".utf8),
                    originalFilename: "live.txt",
                    mediaType: "text/plain",
                    context: producerContext,
                    now: Date(timeIntervalSince1970: 100)
                )
            } catch {
                resultLock.withLock { producerError = error }
            }
            completion.fulfill()
        }

        guard reservationReady.wait(timeout: .now() + 5) == .success else {
            allowFirstCopy.signal()
            XCTFail("First producer did not acquire its live reservation lease")
            return
        }
        var releasedProducer = false
        defer {
            if !releasedProducer { allowFirstCopy.signal() }
        }
        let temporary = containerURL
            .appendingPathComponent(SharedCaptureStore.directoryName, isDirectory: true)
            .appendingPathComponent(SharedCaptureStore.temporaryDirectoryName, isDirectory: true)
        let liveReservation = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: temporary,
                includingPropertiesForKeys: nil
            ).first
        )

        _ = try SharedCaptureStore.enqueueText(
            "future publisher",
            context: identityContext,
            now: Date(timeIntervalSince1970: 4_000_000_000)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: liveReservation.path),
            "Forward clock movement must not reap a producer holding a live lease"
        )

        allowFirstCopy.signal()
        releasedProducer = true
        wait(for: [completion], timeout: 5)
        XCTAssertNil(resultLock.withLock { producerError })
        XCTAssertEqual(try SharedCaptureStore.recoveryItems(context: identityContext).count, 2)
    }

    func testLegacyUserDefaultsQueueMigratesOnceWithoutLosingFile() throws {
        let noCopyFileManager = CopyRejectingSharedCaptureFileManager()
        let context = makeContext(fileManager: noCopyFileManager)
        let legacyRoot = containerURL.appendingPathComponent(SharedCaptureStore.legacyDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyFile = legacyRoot.appendingPathComponent("letter.pdf")
        try Data("legacy-pdf".utf8).write(to: legacyFile)
        let legacyJSON: [[String: Any?]] = [
            ["id": "text-id", "text": "oldest text", "filePath": nil],
            ["id": "file-id", "text": nil, "filePath": legacyFile.path],
        ]
        defaults.set(
            try JSONSerialization.data(
                withJSONObject: legacyJSON.map { row in
                    row.compactMapValues { $0 }
                }),
            forKey: SharedCaptureStore.queueKey
        )
        try SharedCaptureStore.setActiveIdentity("A", context: context)

        let first = try XCTUnwrap(
            SharedCaptureStore.claimNext(
                for: "A",
                context: context,
                now: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(first.payload.text, "oldest text")
        XCTAssertEqual(first.payload.ownerIdentity, "A")
        try SharedCaptureStore.acknowledge(first, context: context)

        let second = try XCTUnwrap(
            SharedCaptureStore.claimNext(
                for: "A",
                context: context,
                now: Date(timeIntervalSince1970: 101)
            )
        )
        XCTAssertNotNil(second.payload.filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(second.payload.filePath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(noCopyFileManager.copyAttempts, 0)
        try SharedCaptureStore.acknowledge(second, context: context)

        XCTAssertNil(defaults.data(forKey: SharedCaptureStore.queueKey))
        XCTAssertNil(try SharedCaptureStore.claimNext(for: "A", context: context))
    }

    func testLegacyIdentifierSanitizationCollisionPreservesBothCaptures() throws {
        let context = makeContext()
        let legacyJSON: [[String: Any?]] = [
            ["id": "same/id", "text": "first", "filePath": nil],
            ["id": "sameid", "text": "second", "filePath": nil],
        ]
        defaults.set(
            try JSONSerialization.data(
                withJSONObject: legacyJSON.map { $0.compactMapValues { $0 } }
            ),
            forKey: SharedCaptureStore.queueKey
        )
        try SharedCaptureStore.setActiveIdentity("A", context: context)

        let first = try XCTUnwrap(
            SharedCaptureStore.claimNext(
                for: "A",
                context: context,
                now: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(first.payload.text, "first")
        try SharedCaptureStore.acknowledge(first, context: context)
        let second = try XCTUnwrap(
            SharedCaptureStore.claimNext(
                for: "A",
                context: context,
                now: Date(timeIntervalSince1970: 101)
            )
        )
        XCTAssertEqual(second.payload.text, "second")
        XCTAssertNotEqual(second.payload.id, first.payload.id)
        try SharedCaptureStore.acknowledge(second, context: context)

        XCTAssertNil(defaults.data(forKey: SharedCaptureStore.queueKey))
    }

    func testRetainedLegacyAssetConsumesAggregateQuota() throws {
        var limits = SharedCaptureStore.Limits()
        limits.maximumItems = 10
        limits.maximumTotalBytes = 6
        limits.maximumReconciliationMutations = 1
        let context = makeContext(limits: limits)
        let legacyRoot = containerURL.appendingPathComponent(
            SharedCaptureStore.legacyDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyFile = legacyRoot.appendingPathComponent("retained.pdf")
        try Data("1234".utf8).write(to: legacyFile)
        let legacy: [SharedCapturePayload] = [
            SharedCapturePayload(id: "first", text: "x", filePath: nil),
            SharedCapturePayload(
                id: "retained",
                text: nil,
                filePath: legacyFile.path,
                originalFilename: "retained.pdf",
                mediaType: "application/pdf"
            ),
        ]
        defaults.set(try JSONEncoder().encode(legacy), forKey: SharedCaptureStore.queueKey)
        try SharedCaptureStore.setActiveIdentity("A", context: context)

        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueText("yy", context: context)
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .inboxFull)
        }

        let retained = try XCTUnwrap(defaults.data(forKey: SharedCaptureStore.queueKey))
        XCTAssertEqual(try JSONDecoder().decode([SharedCapturePayload].self, from: retained).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        let ready = containerURL
            .appendingPathComponent(SharedCaptureStore.directoryName, isDirectory: true)
            .appendingPathComponent(SharedCaptureStore.readyDirectoryName, isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: ready,
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testSymlinkedLegacyRootCannotAdoptOutsideFile() throws {
        let context = makeContext()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SharedCaptureOutside-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = outside.appendingPathComponent("sentinel.pdf")
        let sentinelBytes = Data("outside-private-data".utf8)
        try sentinelBytes.write(to: sentinel)

        let legacyRoot = containerURL.appendingPathComponent(
            SharedCaptureStore.legacyDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: legacyRoot, withDestinationURL: outside)
        let payload = SharedCapturePayload(
            id: "outside",
            text: nil,
            filePath: legacyRoot.appendingPathComponent("sentinel.pdf").path,
            originalFilename: "sentinel.pdf",
            mediaType: "application/pdf"
        )
        defaults.set(try JSONEncoder().encode([payload]), forKey: SharedCaptureStore.queueKey)
        try SharedCaptureStore.setActiveIdentity("A", context: context)

        let reconciliation = try SharedCaptureStore.reconcile(context: context)

        XCTAssertEqual(reconciliation.migratedLegacyItems, 0)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertNotNil(defaults.data(forKey: SharedCaptureStore.queueKey))
        XCTAssertTrue(try SharedCaptureStore.recoveryItems(context: context).isEmpty)
    }

    func testCapsRejectOversizedTextUnsafeNamesUnsupportedTypesAndFullInbox() throws {
        var limits = SharedCaptureStore.Limits()
        limits.maximumItems = 1
        limits.maximumFileBytes = 4
        limits.maximumTextCharacters = 4
        let context = makeContext(limits: limits)

        XCTAssertThrowsError(try SharedCaptureStore.enqueueText("12345", context: context)) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .textTooLong)
        }
        let source = try sourceFile(named: "unsafe.pdf", bytes: Data("12345".utf8))
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueFile(at: source, mediaType: "application/pdf", context: context)
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .fileTooLarge)
        }
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueFileData(
                Data("1".utf8), originalFilename: "../x.pdf", mediaType: "application/pdf", context: context
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .invalidFilename)
        }
        XCTAssertThrowsError(
            try SharedCaptureStore.enqueueFileData(
                Data("1".utf8), originalFilename: "x.zip", mediaType: "application/zip", context: context
            )
        ) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .unsupportedFile)
        }
        _ = try SharedCaptureStore.enqueueText("one", context: context)
        XCTAssertThrowsError(try SharedCaptureStore.enqueueText("two", context: context)) { error in
            XCTAssertEqual(error as? SharedCaptureStoreError, .inboxFull)
        }
    }

    private func makeContext(
        limits: SharedCaptureStore.Limits = SharedCaptureStore.Limits(),
        fileManager: FileManager = .default,
        producerBoundaryDidResolve: (() -> Void)? = nil
    ) -> SharedCaptureStore.Context {
        SharedCaptureStore.Context(
            containerURL: containerURL,
            defaults: defaults,
            fileManager: fileManager,
            limits: limits,
            producerBoundaryDidResolve: producerBoundaryDidResolve
        )
    }

    private func sourceFile(named name: String, bytes: Data) throws -> URL {
        let directory = containerURL.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}

/// Copy-attempt observations are guarded by `lock`; all inherited `FileManager`
/// behavior delegates to Foundation unchanged.
private final class CopyRejectingSharedCaptureFileManager: FileManager {
    private let lock = NSLock()
    private var recordedCopyAttempts = 0

    var copyAttempts: Int {
        lock.withLock { recordedCopyAttempts }
    }

    override func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        lock.withLock { recordedCopyAttempts += 1 }
        throw CocoaError(.fileWriteUnknown)
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
