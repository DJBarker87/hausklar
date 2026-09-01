import Foundation
import UIKit
import XCTest

@testable import HausKlar

final class PhotoPickerPipelineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoPickerPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testRepeatedSelectionsCannotBypassSessionCountLimit() {
        XCTAssertEqual(
            PhotoUploadPrep.permittedSelectionCount(
                existingCount: 28,
                requestedCount: 10,
                maximumCount: 30
            ),
            2
        )
        XCTAssertEqual(
            PhotoUploadPrep.permittedSelectionCount(
                existingCount: 30,
                requestedCount: 1,
                maximumCount: 30
            ),
            0
        )
        XCTAssertEqual(
            PhotoUploadPrep.permittedSelectionCount(
                existingCount: -1,
                requestedCount: 4,
                maximumCount: 30
            ),
            4
        )
    }

    func testAggregateBudgetAcceptsExactLimitAndRejectsGrowthOrOverflow() throws {
        let maximum = 1_024
        XCTAssertEqual(
            try PhotoUploadPrep.checkedAggregateByteCount(
                currentBytes: 768,
                nextBytes: 256,
                maximumBytes: maximum
            ),
            maximum
        )
        XCTAssertThrowsError(
            try PhotoUploadPrep.checkedAggregateByteCount(
                currentBytes: maximum,
                nextBytes: 1,
                maximumBytes: maximum
            )
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .fileTooLarge)
        }
        XCTAssertThrowsError(
            try PhotoUploadPrep.checkedAggregateByteCount(
                currentBytes: Int.max,
                nextBytes: 1,
                maximumBytes: Int.max
            )
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .fileTooLarge)
        }
    }

    func testOwnedStagePreservesProviderOriginalAndCleansOnlyOwnedCopy() throws {
        let providerRoot = root.appendingPathComponent("provider", isDirectory: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: true
        )
        let provider = providerRoot.appendingPathComponent("family-photo.png")
        let original = makePNGData()
        try original.write(to: provider)

        let staged = try PhotoUploadPrep.stageTransferredFile(
            at: provider,
            root: stagingRoot
        )
        XCTAssertNotEqual(staged.fileURL.standardizedFileURL, provider.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: staged.fileURL), original)

        PhotoUploadPrep.removeStagedFile(staged)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
        XCTAssertEqual(try Data(contentsOf: provider), original)
    }

    func testAbandonedTransferAutomaticallyCleansOwnedStage() throws {
        let provider = root.appendingPathComponent("provider.png")
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let original = makePNGData()
        try original.write(to: provider)
        let staged = try PhotoUploadPrep.stageTransferredFile(at: provider, root: stagingRoot)
        var transfer: StagedPhotoTransfer? = StagedPhotoTransfer(owning: staged)

        XCTAssertNotNil(transfer)
        transfer = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directoryURL.path))
        XCTAssertEqual(try Data(contentsOf: provider), original)
    }

    func testTakingTransferMovesCleanupResponsibilityToConsumer() throws {
        let provider = root.appendingPathComponent("provider.png")
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        try makePNGData().write(to: provider)
        let staged = try PhotoUploadPrep.stageTransferredFile(at: provider, root: stagingRoot)
        var transfer: StagedPhotoTransfer? = StagedPhotoTransfer(owning: staged)

        let owned = try XCTUnwrap(transfer).takeStagedFile()
        transfer = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: owned.fileURL.path))
        PhotoUploadPrep.removeStagedFile(owned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
    }

    func testOversizedAndSymbolicLinkProvidersAreRejectedBeforeOwnership() throws {
        let providerRoot = root.appendingPathComponent("provider", isDirectory: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: true
        )
        let oversized = providerRoot.appendingPathComponent("oversized.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PhotoUploadPrep.maximumOriginalBytes + 1))
        try handle.close()

        XCTAssertThrowsError(
            try PhotoUploadPrep.stageTransferredFile(at: oversized, root: stagingRoot)
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .fileTooLarge)
        }

        let target = providerRoot.appendingPathComponent("target.png")
        try makePNGData().write(to: target)
        let link = providerRoot.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try PhotoUploadPrep.stageTransferredFile(at: link, root: stagingRoot)
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .notRegularFile)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testCancellationRemovesPartialOwnedStageAndPreservesProvider() async throws {
        let providerRoot = root.appendingPathComponent("provider", isDirectory: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: providerRoot,
            withIntermediateDirectories: true
        )
        let provider = providerRoot.appendingPathComponent("large-provider.bin")
        let original = Data(repeating: 0xA5, count: 4 * 1_024 * 1_024)
        try original.write(to: provider)
        let beganCopy = expectation(description: "copy began")
        let gate = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try PhotoUploadPrep.stageTransferredFile(
                at: provider,
                root: stagingRoot,
                copyChunkSize: 1_024
            ) { copiedBytes in
                if copiedBytes == 1_024 {
                    beganCopy.fulfill()
                    gate.wait()
                }
            }
        }

        await fulfillment(of: [beganCopy], timeout: 2)
        task.cancel()
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("A cancelled provider copy must not become an owned stage")
        } catch is CancellationError {
            // Expected.
        }

        let stagedEntries = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagedEntries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: provider), original)
    }

    private func makePNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
    }
}
