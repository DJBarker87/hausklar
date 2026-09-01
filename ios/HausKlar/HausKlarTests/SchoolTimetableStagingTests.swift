import Foundation
import XCTest

@testable import HausKlar

final class SchoolTimetableStagingTests: XCTestCase {
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
            "example_school-staging-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeDocument(at url: URL, byteCount: Int) throws {
        precondition(byteCount >= 4)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data([0x50, 0x4B, 0x03, 0x04])
            )
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
    }

    private func ownedEntries(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
    }

    func testExactTwentyFiveMiBDocumentStagesOffMainAndRemovesItsOwnedDirectory() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("School timetable.docx")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        try makeDocument(at: source, byteCount: SchoolTimetableStaging.maximumByteCount)
        let recorder = ThreadRecorder()

        let staged = try await SchoolTimetableStaging.stageSecurityScopedFile(
            at: source,
            rootDirectory: stagingRoot,
            ioProbe: { recorder.record() }
        )

        XCTAssertEqual(staged.byteCount, SchoolTimetableStaging.maximumByteCount)
        XCTAssertEqual(staged.originalFilename, "School timetable.docx")
        XCTAssertEqual(
            try staged.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            SchoolTimetableStaging.maximumByteCount
        )
        XCTAssertTrue(recorder.allOffMain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        await SchoolTimetableStaging.remove(staged, rootDirectory: stagingRoot)
        XCTAssertEqual(try ownedEntries(in: stagingRoot), [])
    }

    func testOneByteOversizeIsRejectedWithoutCreatingAStage() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("oversized.docx")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        try makeDocument(
            at: source,
            byteCount: SchoolTimetableStaging.maximumByteCount + 1
        )

        do {
            _ = try await SchoolTimetableStaging.stageSecurityScopedFile(
                at: source,
                rootDirectory: stagingRoot
            )
            XCTFail("A document above the exact boundary must be rejected")
        } catch SchoolTimetableStagingError.fileTooLarge {
            // Expected.
        }

        XCTAssertEqual(try ownedEntries(in: stagingRoot), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAccountPurgeRemovesAbandonedProtectedStages() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("abandoned.docx")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        try makeDocument(at: source, byteCount: 1_024)
        let staged = try await SchoolTimetableStaging.stageSecurityScopedFile(
            at: source,
            rootDirectory: stagingRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))

        try await SchoolTimetableStaging.purgeAll(rootDirectory: stagingRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSymlinkAndMalformedZIPSignatureFailClosedWithoutTouchingProviderData() async throws {
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("provider.docx")
        let symlink = directory.appendingPathComponent("provider-link.docx")
        let malformed = directory.appendingPathComponent("malformed.docx")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        try makeDocument(at: target, byteCount: 1_024)
        let targetBytes = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        try Data(repeating: 0x41, count: 1_024).write(to: malformed)

        do {
            _ = try await SchoolTimetableStaging.stageSecurityScopedFile(
                at: symlink,
                rootDirectory: stagingRoot
            )
            XCTFail("A symbolic link must never be followed")
        } catch SchoolTimetableStagingError.invalidSource {
            // Expected.
        }

        do {
            _ = try await SchoolTimetableStaging.stageSecurityScopedFile(
                at: malformed,
                rootDirectory: stagingRoot
            )
            XCTFail("A .docx extension without a ZIP local-header signature must fail")
        } catch SchoolTimetableStagingError.malformedDocument {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: target), targetBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertEqual(try ownedEntries(in: stagingRoot), [])
    }

    func testCancellationBeforeStreamingLeavesNoOwnedArtifact() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("cancelled.docx")
        let stagingRoot = directory.appendingPathComponent("staging", isDirectory: true)
        try makeDocument(at: source, byteCount: 4 * 1_024 * 1_024)
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)

        let task = Task {
            try await SchoolTimetableStaging.stageSecurityScopedFile(
                at: source,
                rootDirectory: stagingRoot,
                ioProbe: {
                    started.signal()
                    proceed.wait()
                }
            )
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        task.cancel()
        proceed.signal()

        do {
            _ = try await task.value
            XCTFail("A cancelled stage must not be published")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try ownedEntries(in: stagingRoot), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
