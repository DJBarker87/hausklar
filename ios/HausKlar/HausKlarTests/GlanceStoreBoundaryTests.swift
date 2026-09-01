import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import HausKlar

final class GlanceStoreBoundaryTests: XCTestCase {
    private func temporaryFile(containing data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-cache-boundary-\(UUID().uuidString)")
        try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    func testBoundedCacheReadAcceptsExactLimitAndRejectsOversizedFile() throws {
        let file = try temporaryFile(containing: Data(repeating: 0x41, count: 16))

        XCTAssertEqual(GlanceStore.boundedCacheData(at: file, maximumBytes: 16)?.count, 16)
        XCTAssertNil(GlanceStore.boundedCacheData(at: file, maximumBytes: 15))
    }

    func testBoundedCacheReadRejectsSymlinkWithoutReadingTarget() throws {
        let target = try temporaryFile(containing: Data("private cache".utf8))
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-cache-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        XCTAssertNil(GlanceStore.boundedCacheData(at: link, maximumBytes: 1_024))
        XCTAssertEqual(try Data(contentsOf: target), Data("private cache".utf8))
    }

    func testMemoryPipelineCreatesSingleFrameJPEGAtExactPixelBoundary() throws {
        let source = try temporaryImageFile(
            data: encodedImage(width: 640, height: 320, type: "public.jpeg")
        )

        let derivative = try GlanceMemoryThumbnailPipeline.makeDerivative(from: source)
        let image = try GlanceMemoryThumbnailPipeline.validatedDerivativeImage(derivative)
        let decodedSource = try XCTUnwrap(
            CGImageSourceCreateWithData(derivative as CFData, nil)
        )

        XCTAssertEqual(CGImageSourceGetCount(decodedSource), 1)
        XCTAssertEqual(CGImageSourceGetType(decodedSource) as String?, "public.jpeg")
        XCTAssertEqual(image.width, GlanceMemoryThumbnailPipeline.maximumPixelDimension)
        XCTAssertEqual(image.height, 80)
        XCTAssertLessThanOrEqual(
            derivative.count,
            GlanceMemoryThumbnailPipeline.maximumEncodedBytes
        )
    }

    func testMemoryPipelineAcceptsExactSourceByteCapAndRejectsNextByte() throws {
        let jpeg = try encodedImage(width: 64, height: 64, type: "public.jpeg")
        var exact = jpeg
        exact.append(
            Data(
                repeating: 0,
                count: GlanceMemoryThumbnailPipeline.maximumSourceBytes - jpeg.count
            )
        )
        let exactFile = try temporaryImageFile(data: exact)
        XCTAssertNoThrow(
            try GlanceMemoryThumbnailPipeline.makeDerivative(from: exactFile)
        )

        var oversized = exact
        oversized.append(0)
        let oversizedFile = try temporaryImageFile(data: oversized)
        XCTAssertThrowsError(
            try GlanceMemoryThumbnailPipeline.makeDerivative(from: oversizedFile)
        ) { error in
            XCTAssertEqual(
                error as? GlanceMemoryThumbnailPipeline.ValidationError,
                .sourceSizeExceedsMaximum
            )
        }
    }

    func testWidgetDerivativeAcceptsExactEncodedCapAndRejectsNextByte() throws {
        let source = try temporaryImageFile(
            data: encodedImage(width: 160, height: 160, type: "public.jpeg")
        )
        let derivative = try GlanceMemoryThumbnailPipeline.makeDerivative(from: source)
        var exact = derivative
        exact.append(
            Data(
                repeating: 0,
                count: GlanceMemoryThumbnailPipeline.maximumEncodedBytes - derivative.count
            )
        )

        XCTAssertNoThrow(
            try GlanceMemoryThumbnailPipeline.validatedDerivativeImage(exact)
        )
        exact.append(0)
        XCTAssertThrowsError(
            try GlanceMemoryThumbnailPipeline.validatedDerivativeImage(exact)
        ) { error in
            XCTAssertEqual(
                error as? GlanceMemoryThumbnailPipeline.ValidationError,
                .encodedSizeExceedsMaximum
            )
        }
    }

    func testMemoryPipelineRejectsMalformedMultiFrameAndDimensionBombSources() throws {
        let malformed = try temporaryImageFile(data: Data("not an image".utf8))
        XCTAssertThrowsError(
            try GlanceMemoryThumbnailPipeline.makeDerivative(from: malformed)
        )

        let gif = try temporaryImageFile(
            data: encodedImage(
                width: 8,
                height: 8,
                type: "com.compuserve.gif",
                frameCount: 2
            )
        )
        XCTAssertThrowsError(
            try GlanceMemoryThumbnailPipeline.makeDerivative(from: gif)
        ) { error in
            XCTAssertEqual(
                error as? GlanceMemoryThumbnailPipeline.ValidationError,
                .multipleFrames
            )
        }

        let bomb = try temporaryImageFile(
            data: pngHeader(width: 100_000, height: 100_000)
        )
        XCTAssertThrowsError(
            try GlanceMemoryThumbnailPipeline.makeDerivative(from: bomb)
        ) { error in
            XCTAssertEqual(
                error as? GlanceMemoryThumbnailPipeline.ValidationError,
                .invalidDimensions
            )
        }
    }

    func testMemoryPipelineRejectsDirectoryAndSymlinkSources() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-image-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(
            try GlanceMemoryThumbnailPipeline.makeDerivative(from: directory)
        ) { error in
            XCTAssertEqual(
                error as? GlanceMemoryThumbnailPipeline.ValidationError,
                .invalidSourceFile
            )
        }

        let target = try temporaryImageFile(
            data: encodedImage(width: 32, height: 32, type: "public.jpeg")
        )
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-image-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        XCTAssertThrowsError(
            try GlanceMemoryThumbnailPipeline.makeDerivative(from: link)
        ) { error in
            XCTAssertEqual(
                error as? GlanceMemoryThumbnailPipeline.ValidationError,
                .invalidSourceFile
            )
        }
    }

    func testMemoryCachePathIsOwnerAndAssetScopedAndAccountChangeClearsIt() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-owner-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        let defaultsSuite = "GlanceOwnerBoundary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        addTeardownBlock { defaults.removePersistentDomain(forName: defaultsSuite) }

        let ownerA = "family-a:user-a"
        let ownerB = "family-b:user-b"
        let assetA = "asset-0001"
        let assetB = "asset-0002"
        GlanceStore.activate(
            identity: ownerA,
            defaults: defaults,
            containerURL: container
        )
        let source = try temporaryImageFile(
            data: encodedImage(width: 320, height: 240, type: "public.jpeg")
        )
        let derivative = try GlanceMemoryThumbnailPipeline.makeDerivative(from: source)
        try GlanceStore.saveMemoryThumbnail(
            derivative,
            assetId: assetA,
            ownerIdentity: ownerA,
            containerURL: container
        )

        let ownerAURL = try XCTUnwrap(GlanceStore.memoryThumbnailFileURL(
            containerURL: container,
            ownerIdentity: ownerA,
            assetId: assetA
        ))
        let ownerBURL = try XCTUnwrap(GlanceStore.memoryThumbnailFileURL(
            containerURL: container,
            ownerIdentity: ownerB,
            assetId: assetA
        ))
        let assetBURL = try XCTUnwrap(GlanceStore.memoryThumbnailFileURL(
            containerURL: container,
            ownerIdentity: ownerA,
            assetId: assetB
        ))
        XCTAssertNotEqual(ownerAURL, ownerBURL)
        XCTAssertNotEqual(ownerAURL, assetBURL)
        XCTAssertFalse(ownerAURL.path.contains(ownerA))
        XCTAssertFalse(ownerAURL.path.contains(assetA))
        XCTAssertEqual(
            GlanceStore.loadMemoryThumbnail(
                assetId: assetA,
                ownerIdentity: ownerA,
                containerURL: container
            )?.image,
            derivative
        )
        XCTAssertNil(GlanceStore.loadMemoryThumbnail(
            assetId: assetA,
            ownerIdentity: ownerB,
            containerURL: container
        ))

        GlanceStore.activate(
            identity: ownerB,
            defaults: defaults,
            containerURL: container
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerAURL.path))
        XCTAssertEqual(defaults.string(forKey: "glance.activeOwner"), ownerB)
    }

    func testMemoryCacheRejectsTamperedDimensionBombBeforeWidgetDecode() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-tampered-cache-\(UUID().uuidString)", isDirectory: true)
        let owner = "family-a:user-a"
        let asset = "asset-0001"
        let file = try XCTUnwrap(GlanceStore.memoryThumbnailFileURL(
            containerURL: container,
            ownerIdentity: owner,
            assetId: asset
        ))
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngHeader(width: 100_000, height: 100_000).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }

        XCTAssertNil(GlanceStore.loadMemoryThumbnail(
            assetId: asset,
            ownerIdentity: owner,
            containerURL: container
        ))
    }

    private func temporaryImageFile(data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-image-boundary-\(UUID().uuidString)")
        try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    private func encodedImage(
        width: Int,
        height: Int,
        type: String,
        frameCount: Int = 1
    ) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.18, green: 0.46, blue: 0.72, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            type as CFString,
            frameCount,
            nil
        ))
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A metadata-complete PNG with intentionally absent pixel data. ImageIO can
    /// inspect its dimensions, while the production guard rejects it before any
    /// decoder attempts the declared 10-gigapixel allocation.
    private func pngHeader(width: UInt32, height: UInt32) -> Data {
        var result = Data([137, 80, 78, 71, 13, 10, 26, 10])
        var header = Data()
        header.append(bigEndianBytes(width))
        header.append(bigEndianBytes(height))
        header.append(contentsOf: [8, 2, 0, 0, 0])
        result.append(pngChunk(type: "IHDR", payload: header))
        result.append(pngChunk(type: "IEND", payload: Data()))
        return result
    }

    private func pngChunk(type: String, payload: Data) -> Data {
        let typeData = Data(type.utf8)
        var result = bigEndianBytes(UInt32(payload.count))
        result.append(typeData)
        result.append(payload)
        result.append(bigEndianBytes(crc32(typeData + payload)))
        return result
    }

    private func bigEndianBytes(_ value: UInt32) -> Data {
        let bigEndian = value.bigEndian
        return withUnsafeBytes(of: bigEndian) { Data($0) }
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(0) &- (crc & 1)
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ UInt32.max
    }
}
