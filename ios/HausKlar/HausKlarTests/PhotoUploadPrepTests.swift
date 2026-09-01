import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import HausKlar

final class PhotoUploadPrepTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoUploadPrepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
    }

    func testStagingCopiesOriginalBytesIntoUniqueProtectedDirectory() throws {
        let original = try write(makePNGData(), named: "provider.png")

        let first = try PhotoUploadPrep.stageTransferredFile(at: original, root: root)
        let second = try PhotoUploadPrep.stageTransferredFile(at: original, root: root)
        defer {
            PhotoUploadPrep.removeStagedFile(first)
            PhotoUploadPrep.removeStagedFile(second)
        }

        XCTAssertNotEqual(first.directoryURL, second.directoryURL)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), try Data(contentsOf: original))
        XCTAssertEqual(try Data(contentsOf: second.fileURL), try Data(contentsOf: original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let values = try first.fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertNotEqual(values.isSymbolicLink, true)
    }

    func testGeneratedJPEGUsesOwnedReconciledStageAndRejectsOtherFormats() throws {
        let jpeg = try makeJPEGData(captureDate: "2026:08:10 09:15:00")
        let staged = try PhotoUploadPrep.stageGeneratedJPEG(jpeg, root: root)

        XCTAssertEqual(try Data(contentsOf: staged.fileURL), jpeg)
        XCTAssertEqual(staged.fileURL.lastPathComponent, "original")
        XCTAssertEqual(staged.directoryURL.deletingLastPathComponent(), root)
        PhotoUploadPrep.removeStagedFile(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directoryURL.path))

        XCTAssertThrowsError(
            try PhotoUploadPrep.stageGeneratedJPEG(makePNGData(), root: root)
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .unsupportedImage)
        }
    }

    func testCleanupRequiresAnOwnedStagingCapability() throws {
        let providerDirectory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: providerDirectory,
            withIntermediateDirectories: true
        )
        let providerFile = providerDirectory.appendingPathComponent("original")
        try makePNGData().write(to: providerFile)
        let forged = PhotoUploadPrep.StagedFile(
            directoryURL: providerDirectory,
            fileURL: providerFile
        )

        PhotoUploadPrep.removeStagedFile(forged)

        XCTAssertTrue(FileManager.default.fileExists(atPath: providerFile.path))
    }

    func testOversizedProviderFileIsRejectedBeforeCopy() throws {
        let source = root.appendingPathComponent("oversized.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(PhotoUploadPrep.maximumOriginalBytes + 1))
        try handle.close()

        XCTAssertThrowsError(
            try PhotoUploadPrep.stageTransferredFile(at: source, root: root)
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .fileTooLarge)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["oversized.jpg"])
    }

    func testSymbolicLinkProviderIsRejectedWithoutReadingTarget() throws {
        let target = try write(makePNGData(), named: "target.png")
        let link = root.appendingPathComponent("provider-link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try PhotoUploadPrep.stageTransferredFile(at: link, root: root)
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .notRegularFile)
        }
    }

    func testMetadataHelpersRejectOversizedFilesAndSymbolicLinks() throws {
        let source = try write(
            try makeJPEGData(captureDate: "2026:08:10 09:15:00"),
            named: "dated.jpg"
        )
        XCTAssertNotNil(PhotoUploadPrep.captureDate(at: source))
        XCTAssertEqual(PhotoUploadPrep.fileMetadata(at: source)?.mediaType, "image/jpeg")

        let symbolicLink = root.appendingPathComponent("dated-link.jpg")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)
        XCTAssertNil(PhotoUploadPrep.captureDate(at: symbolicLink))
        XCTAssertNil(PhotoUploadPrep.fileMetadata(at: symbolicLink))

        let oversized = root.appendingPathComponent("oversized-metadata.jpg")
        try Data(contentsOf: source).write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(PhotoUploadPrep.maximumOriginalBytes + 1))
        try handle.close()
        XCTAssertNil(PhotoUploadPrep.captureDate(at: oversized))
        XCTAssertNil(PhotoUploadPrep.fileMetadata(at: oversized))

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDeclaredTypeMustMatchImageIOMagic() throws {
        let source = try write(makePNGData(), named: "actual.png")
        let staged = try PhotoUploadPrep.stageTransferredFile(at: source, root: root)
        defer { PhotoUploadPrep.removeStagedFile(staged) }

        XCTAssertThrowsError(
            try PhotoUploadPrep.prepareStagedFile(
                staged,
                declaredTypeIdentifiers: [UTType.jpeg.identifier],
                childId: "child-1"
            )
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .declaredTypeMismatch)
        }
    }

    func testMalformedImageIsRejectedBeforeHashAndUpload() throws {
        let source = try write(Data("not an image".utf8), named: "fake.jpg")
        let staged = try PhotoUploadPrep.stageTransferredFile(at: source, root: root)
        defer { PhotoUploadPrep.removeStagedFile(staged) }

        XCTAssertThrowsError(
            try PhotoUploadPrep.prepareStagedFile(
                staged,
                declaredTypeIdentifiers: [UTType.jpeg.identifier],
                childId: "child-1"
            )
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .unsupportedImage)
        }
    }

    func testHugeTIFFDimensionsAreRejectedWithoutDecodingPixels() throws {
        let source = try write(minimalTIFF(width: 50_000, height: 50_000), named: "huge.tiff")
        let staged = try PhotoUploadPrep.stageTransferredFile(at: source, root: root)
        defer { PhotoUploadPrep.removeStagedFile(staged) }

        XCTAssertThrowsError(
            try PhotoUploadPrep.prepareStagedFile(
                staged,
                declaredTypeIdentifiers: [UTType.tiff.identifier],
                childId: "child-1"
            )
        ) { error in
            XCTAssertEqual(error as? PhotoUploadPrepError, .unsafeDimensions)
        }
    }

    func testStableClientIDUsesStreamedContentDigestAndChildScope() throws {
        let source = try write(makePNGData(), named: "moment.png")
        let first = try PhotoUploadPrep.stageTransferredFile(at: source, root: root)
        let second = try PhotoUploadPrep.stageTransferredFile(at: source, root: root)
        let third = try PhotoUploadPrep.stageTransferredFile(at: source, root: root)
        defer {
            PhotoUploadPrep.removeStagedFile(first)
            PhotoUploadPrep.removeStagedFile(second)
            PhotoUploadPrep.removeStagedFile(third)
        }

        let firstPrepared = try PhotoUploadPrep.prepareStagedFile(
            first,
            declaredTypeIdentifiers: [UTType.png.identifier],
            childId: "child-1"
        )
        let retryPrepared = try PhotoUploadPrep.prepareStagedFile(
            second,
            declaredTypeIdentifiers: [UTType.image.identifier],
            childId: "child-1"
        )
        let otherChild = try PhotoUploadPrep.prepareStagedFile(
            third,
            declaredTypeIdentifiers: [UTType.png.identifier],
            childId: "child-2"
        )

        XCTAssertEqual(firstPrepared.clientId, retryPrepared.clientId)
        XCTAssertEqual(firstPrepared.sha256, retryPrepared.sha256)
        XCTAssertNotEqual(firstPrepared.clientId, otherChild.clientId)
        XCTAssertLessThanOrEqual(firstPrepared.clientId.count, 100)
    }

    func testBatchingObeysFileAndRequestByteCaps() throws {
        let mib = 1_024 * 1_024
        let byteCounts = [25 * mib, 25 * mib, 25 * mib, 20 * mib, 4 * mib, 1 * mib]
        let batches = try PhotoUploadPrep.batchIndices(forByteCounts: byteCounts)

        XCTAssertEqual(batches.flatMap { $0 }, Array(byteCounts.indices))
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.count, PhotoUploadPrep.maximumFilesPerBatch)
            XCTAssertLessThanOrEqual(
                batch.reduce(0) { $0 + byteCounts[$1] },
                PhotoUploadPrep.maximumBatchFileBytes
            )
        }
        XCTAssertEqual(batches.first, [0, 1])
    }

    func testThirtyInputsProduceSixBoundedBatches() throws {
        let byteCounts = Array(repeating: 1_024, count: 30)
        let batches = try PhotoUploadPrep.batchIndices(forByteCounts: byteCounts)

        XCTAssertEqual(batches.count, 6)
        XCTAssertTrue(batches.allSatisfy { $0.count == 5 })
        XCTAssertEqual(batches.flatMap { $0 }, Array(0..<30))
    }

    func testCancellationRemovesPartiallyCopiedStagingDirectory() async throws {
        let source = try write(Data(repeating: 0xA5, count: 4 * 1_024 * 1_024), named: "large.bin")
        let stagingRoot = try XCTUnwrap(root)
        let beganCopy = expectation(description: "copy began")
        let gate = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try PhotoUploadPrep.stageTransferredFile(
                at: source,
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
            XCTFail("A cancelled staging copy must not succeed")
        } catch is CancellationError {
            // Expected.
        }

        let remaining = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        XCTAssertEqual(remaining, [source])
    }

    func testReconciliationDeletesOnlyOldOwnedStagingWithABoundedSweep() throws {
        let provider = try write(makePNGData(), named: "provider.png")
        let firstOld = try PhotoUploadPrep.stageTransferredFile(at: provider, root: root)
        let secondOld = try PhotoUploadPrep.stageTransferredFile(at: provider, root: root)
        let fresh = try PhotoUploadPrep.stageTransferredFile(at: provider, root: root)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = now.addingTimeInterval(-7_200)
        for staged in [firstOld, secondOld] {
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: staged.fileURL.path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: staged.directoryURL.path
            )
        }

        let externalTarget = root.appendingPathComponent("provider-owned", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTarget, withIntermediateDirectories: true)
        let symbolicLink = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: externalTarget
        )
        let nearMiss = root.appendingPathComponent("manual-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nearMiss, withIntermediateDirectories: true)

        let firstPass = PhotoUploadPrep.reconcileStagedFiles(
            at: root,
            now: now,
            minimumAge: 3_600,
            maximumCandidates: 32,
            maximumRemovals: 1
        )

        XCTAssertEqual(firstPass, 1)
        XCTAssertEqual(
            [firstOld, secondOld].filter {
                FileManager.default.fileExists(atPath: $0.directoryURL.path)
            }.count,
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: provider.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nearMiss.path))

        let secondPass = PhotoUploadPrep.reconcileStagedFiles(
            at: root,
            now: now,
            minimumAge: 3_600,
            maximumCandidates: 32,
            maximumRemovals: 32
        )
        XCTAssertEqual(secondPass, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstOld.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondOld.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
    }

    func testUnsafeFullDecodeFallbackWasRemoved() {
        XCTAssertNil(PhotoUploadPrep.downsampledJPEG(from: Data("not an image".utf8)))
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func makePNGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6))
        return renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
    }

    private func makeJPEGData(captureDate: String) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: captureDate
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFDateTime: captureDate
            ],
        ]
        CGImageDestinationAddImage(
            destination,
            try XCTUnwrap(image.cgImage),
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return output as Data
    }

    /// A metadata-only little-endian TIFF. ImageIO can inspect its IFD dimensions
    /// without allocating a 50,000 x 50,000 pixel buffer.
    private func minimalTIFF(width: UInt32, height: UInt32) -> Data {
        var bytes = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
        append(UInt16(2), to: &bytes)  // two IFD entries
        appendTIFFDimension(tag: 256, value: width, to: &bytes)
        appendTIFFDimension(tag: 257, value: height, to: &bytes)
        append(UInt32(0), to: &bytes)  // no next IFD
        return bytes
    }

    private func appendTIFFDimension(tag: UInt16, value: UInt32, to data: inout Data) {
        append(tag, to: &data)
        append(UInt16(4), to: &data)  // LONG
        append(UInt32(1), to: &data)
        append(value, to: &data)
    }

    private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
