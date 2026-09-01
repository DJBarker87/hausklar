import UIKit
import XCTest

@testable import HausKlar

@MainActor
final class DecodedImageCacheTests: XCTestCase {
    private actor SuspendedLoad {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Data, Never>?

        func value(_ data: Data) async -> Data {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            return await withCheckedContinuation { release = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func resume(with data: Data) {
            release?.resume(returning: data)
            release = nil
        }
    }

    private actor ConcurrencyProbe {
        private(set) var maximumObserved = 0
        private var active = 0

        func load(_ data: Data) async throws -> Data {
            active += 1
            maximumObserved = max(maximumObserved, active)
            try await Task.sleep(for: .milliseconds(25))
            active -= 1
            return data
        }
    }

    func testDownsamplesAtRequestedScaleAndBoundsHistoryByCostAndCount() async throws {
        var limits = DecodedImageCache.Limits()
        limits.maximumDecodedBytes = 128 * 1_024
        limits.maximumEntries = 3
        let cache = DecodedImageCache(
            limits: limits,
            displayScale: 3,
            observesMemoryWarnings: false
        )
        let lease = cache.activate(identity: "family-a:user-a")
        let source = try imageData(width: 1_200, height: 600)

        let first = await cache.image(
            kind: .childPhotoThumbnail,
            resourceID: "photo-0",
            maximumPixelSize: 120,
            lease: lease
        ) { source }
        let firstImage = try XCTUnwrap(first)
        XCTAssertEqual(firstImage.cgImage?.width, 120)
        XCTAssertEqual(firstImage.cgImage?.height, 60)
        XCTAssertEqual(firstImage.scale, 3)

        for index in 1..<20 {
            _ = await cache.image(
                kind: .childPhotoThumbnail,
                resourceID: "photo-\(index)",
                maximumPixelSize: 120,
                lease: lease
            ) { source }
        }

        let snapshot = cache.snapshot()
        XCTAssertLessThanOrEqual(snapshot.entryCount, limits.maximumEntries)
        XCTAssertLessThanOrEqual(snapshot.decodedBytes, limits.maximumDecodedBytes)
    }

    func testAccountChangeRejectsLatePriorOwnerAndClearsDecodedEntries() async throws {
        let cache = DecodedImageCache(observesMemoryWarnings: false)
        let firstLease = cache.activate(identity: "family-a:user-a")
        let source = try imageData(width: 80, height: 40)
        let suspended = SuspendedLoad()
        let task = Task { @MainActor in
            await cache.image(
                kind: .artworkThumbnail,
                resourceID: "artwork-a",
                maximumPixelSize: 40,
                lease: firstLease
            ) {
                await suspended.value(source)
            }
        }
        await suspended.waitUntilStarted()

        let secondLease = cache.activate(identity: "family-b:user-b")
        await suspended.resume(with: source)
        let priorOwnerImage = await task.value
        XCTAssertNil(priorOwnerImage)
        XCTAssertEqual(cache.snapshot().entryCount, 0)

        let secondOwnerImage = await cache.image(
            kind: .artworkThumbnail,
            resourceID: "artwork-b",
            maximumPixelSize: 40,
            lease: secondLease
        ) { source }
        XCTAssertNotNil(secondOwnerImage)
        XCTAssertEqual(cache.snapshot().entryCount, 1)
    }

    func testMemoryPressurePurgesEntriesKeepsOwnerAndInvalidatesOldLease() async throws {
        let cache = DecodedImageCache(observesMemoryWarnings: false)
        let oldLease = cache.activate(identity: "family-a:user-a")
        let source = try imageData(width: 80, height: 40)
        let firstImage = await cache.image(
            kind: .photoArchiveThumbnail,
            resourceID: "memory-a",
            maximumPixelSize: 40,
            lease: oldLease
        ) { source }
        XCTAssertNotNil(firstImage)

        cache.handleMemoryPressure()
        let snapshot = cache.snapshot()
        XCTAssertEqual(snapshot.entryCount, 0)
        XCTAssertEqual(snapshot.decodedBytes, 0)
        XCTAssertTrue(snapshot.hasActiveOwner)
        let staleImage = await cache.image(
            kind: .photoArchiveThumbnail,
            resourceID: "stale",
            maximumPixelSize: 40,
            lease: oldLease
        ) { source }
        XCTAssertNil(staleImage)
        let currentLease = try XCTUnwrap(cache.currentLease())
        XCTAssertNotEqual(currentLease, oldLease)
    }

    func testGlobalFetchConcurrencyNeverExceedsConfiguredLimit() async throws {
        var limits = DecodedImageCache.Limits()
        limits.maximumConcurrentLoads = 2
        let cache = DecodedImageCache(limits: limits, observesMemoryWarnings: false)
        let lease = cache.activate(identity: "family-a:user-a")
        let source = try imageData(width: 80, height: 40)
        let probe = ConcurrencyProbe()

        let tasks = (0..<10).map { index in
            Task { @MainActor in
                await cache.image(
                    kind: .photoArchiveThumbnail,
                    resourceID: "asset-\(index)",
                    maximumPixelSize: 40,
                    lease: lease
                ) {
                    try await probe.load(source)
                }
            }
        }
        for task in tasks {
            let image = await task.value
            XCTAssertNotNil(image)
        }
        let maximumObserved = await probe.maximumObserved
        XCTAssertEqual(maximumObserved, 2)
    }

    private func imageData(width: Int, height: Int) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor.systemTeal.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.pngData())
    }
}
