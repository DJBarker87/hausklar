import Foundation
import XCTest

@testable import HausKlar

final class FileCacheBoundaryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-cache-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testOversizedDurableIndexFailsClosedBeforeDecoding() throws {
        let directory = try temporaryDirectory()
        let index = directory.appendingPathComponent(".hausklar-cache-index-v1.json")
        try Data(repeating: 0x41, count: 8 * 1_024 * 1_024 + 1).write(to: index)

        _ = FileCache(cacheDir: directory)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testEntryLargerThanDiskQuotaRemainsMemoryOnly() async throws {
        let directory = try temporaryDirectory()
        let cache = FileCache(cacheDir: directory, maxDiskBytes: 8)
        let payload = Data("123456789".utf8)

        await cache.set("account-scoped-key", data: payload)

        let cached = await cache.get("account-scoped-key")
        XCTAssertEqual(cached?.data, payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])

        let relaunched = FileCache(cacheDir: directory, maxDiskBytes: 8)
        let restored = await relaunched.get("account-scoped-key")
        XCTAssertNil(restored)
    }

    func testBoundedGetRejectsBeforeDiskReadWithoutEvictingValidEntry() async throws {
        let directory = try temporaryDirectory()
        let key = "strict-binary-policy"
        let payload = Data(repeating: 0x5A, count: 32)
        let writer = FileCache(cacheDir: directory)
        await writer.set(key, data: payload)

        let coldReader = FileCache(cacheDir: directory)
        let rejected = await coldReader.get(key, maximumBytes: 31)
        let accepted = await coldReader.get(key, maximumBytes: 32)
        XCTAssertNil(rejected)
        XCTAssertEqual(accepted?.data, payload)

        let verifiedRelaunch = FileCache(cacheDir: directory)
        let restored = await verifiedRelaunch.get(key, maximumBytes: 32)
        XCTAssertEqual(restored?.data, payload)
    }

    func testBoundedGetRejectsNonpositiveLimitsWithoutEvictingMemoryEntry() async throws {
        let directory = try temporaryDirectory()
        let key = "memory-policy"
        let payload = Data("private".utf8)
        let cache = FileCache(cacheDir: directory)
        await cache.set(key, data: payload)

        let zero = await cache.get(key, maximumBytes: 0)
        let negative = await cache.get(key, maximumBytes: -1)
        let tooSmall = await cache.get(key, maximumBytes: payload.count - 1)
        let accepted = await cache.get(key, maximumBytes: payload.count)
        XCTAssertNil(zero)
        XCTAssertNil(negative)
        XCTAssertNil(tooSmall)
        XCTAssertEqual(accepted?.data, payload)
    }

    func testBoundedGetEvictsPayloadWhoseStatNoLongerMatchesIndex() async throws {
        let directory = try temporaryDirectory()
        let key = "mutated-payload"
        let payload = Data("indexed".utf8)
        let writer = FileCache(cacheDir: directory)
        await writer.set(key, data: payload)
        let coldReader = FileCache(cacheDir: directory)

        let payloadURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { !$0.lastPathComponent.hasPrefix(".hausklar-cache-index") }
        )
        let handle = try FileHandle(forWritingTo: payloadURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tamper".utf8))
        try handle.close()

        // Even though the indexed entry is already above this caller's policy,
        // the cheap stat check still detects and evicts the corrupted payload.
        let mutated = await coldReader.get(key, maximumBytes: 1)
        XCTAssertNil(mutated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
        let relaunched = FileCache(cacheDir: directory)
        let restored = await relaunched.get(key, maximumBytes: 1_024)
        XCTAssertNil(restored)
    }
}
