import XCTest

@testable import HausKlar

final class HausKlarModelContainerFactoryTests: XCTestCase {
    private enum TestError: Error {
        case protection
        case open
        case archive
    }

    private let storeURL = URL(fileURLWithPath: "/tmp/hausklar-test-store.sqlite")

    func testPersistentSuccessNeverArchivesOrMarksRecovery() throws {
        var calls: [String] = []
        let result: PersistentStoreBootstrapResult<Int> = PersistentStoreBootstrap.run(
            storeURL: storeURL,
            protect: { _ in calls.append("protect") },
            openPersistent: {
                calls.append("open")
                return 42
            },
            archive: { _ in
                calls.append("archive")
                return self.storeURL
            },
            markRecovered: { calls.append("mark") }
        )

        XCTAssertEqual(try XCTUnwrap(result.container), 42)
        XCTAssertEqual(calls, ["protect", "open", "protect"])
        guard case .ready(_, let recovered, let archiveURL) = result else {
            return XCTFail("Expected a persistent container")
        }
        XCTAssertFalse(recovered)
        XCTAssertNil(archiveURL)
    }

    func testFailedOpenArchivesThenPublishesOnlyVerifiedPersistentRecovery() throws {
        var calls: [String] = []
        var openCount = 0
        let archiveURL = URL(fileURLWithPath: "/tmp/hausklar-recovery/archive")
        let result: PersistentStoreBootstrapResult<Int> = PersistentStoreBootstrap.run(
            storeURL: storeURL,
            protect: { _ in calls.append("protect") },
            openPersistent: {
                openCount += 1
                calls.append("open-\(openCount)")
                if openCount == 1 { throw TestError.open }
                return 7
            },
            archive: { _ in
                calls.append("archive")
                return archiveURL
            },
            markRecovered: { calls.append("mark") }
        )

        XCTAssertEqual(try XCTUnwrap(result.container), 7)
        XCTAssertEqual(calls, ["protect", "open-1", "archive", "open-2", "protect", "mark"])
        guard case .ready(_, let recovered, let publishedArchive) = result else {
            return XCTFail("Expected a recovered persistent container")
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(publishedArchive, archiveURL)
    }

    func testInitialProtectionFailureDoesNotOpenArchiveOrActivate() {
        var calls: [String] = []
        let result: PersistentStoreBootstrapResult<Int> = PersistentStoreBootstrap.run(
            storeURL: storeURL,
            protect: { _ in
                calls.append("protect")
                throw TestError.protection
            },
            openPersistent: {
                calls.append("open")
                return 1
            },
            archive: { _ in
                calls.append("archive")
                return self.storeURL
            },
            markRecovered: { calls.append("mark") }
        )

        XCTAssertNil(result.container)
        XCTAssertEqual(calls, ["protect"])
        assertFailure(result, stage: .initialProtection)
    }

    func testArchiveFailureReturnsNoVolatileContainer() {
        var openCount = 0
        var marked = false
        let result: PersistentStoreBootstrapResult<Int> = PersistentStoreBootstrap.run(
            storeURL: storeURL,
            protect: { _ in },
            openPersistent: {
                openCount += 1
                throw TestError.open
            },
            archive: { _ in throw TestError.archive },
            markRecovered: { marked = true }
        )

        XCTAssertNil(result.container)
        XCTAssertEqual(openCount, 1)
        XCTAssertFalse(marked)
        assertFailure(result, stage: .recovery)
    }

    func testRecreatedOpenFailureReturnsNoVolatileContainer() {
        var openCount = 0
        let result: PersistentStoreBootstrapResult<Int> = PersistentStoreBootstrap.run(
            storeURL: storeURL,
            protect: { _ in },
            openPersistent: {
                openCount += 1
                throw TestError.open
            },
            archive: { _ in self.storeURL },
            markRecovered: { XCTFail("A failed recovery must not be marked") }
        )

        XCTAssertNil(result.container)
        XCTAssertEqual(openCount, 2)
        assertFailure(result, stage: .recovery)
    }

    func testPostOpenProtectionFailureReturnsNoContainer() {
        var protectCount = 0
        let result: PersistentStoreBootstrapResult<Int> = PersistentStoreBootstrap.run(
            storeURL: storeURL,
            protect: { _ in
                protectCount += 1
                if protectCount == 2 { throw TestError.protection }
            },
            openPersistent: { 1 },
            archive: { _ in
                XCTFail("An open store must not be archived while its container is alive")
                return self.storeURL
            },
            markRecovered: { XCTFail("This was not a recovery") }
        )

        XCTAssertNil(result.container)
        assertFailure(result, stage: .finalProtection)
    }

    func testRecoveredStoreProtectionFailureStillFailsClosed() {
        var openCount = 0
        var protectCount = 0
        let result: PersistentStoreBootstrapResult<Int> = PersistentStoreBootstrap.run(
            storeURL: storeURL,
            protect: { _ in
                protectCount += 1
                if protectCount == 2 { throw TestError.protection }
            },
            openPersistent: {
                openCount += 1
                if openCount == 1 { throw TestError.open }
                return 9
            },
            archive: { _ in self.storeURL },
            markRecovered: { XCTFail("Unprotected recovery must not be marked") }
        )

        XCTAssertNil(result.container)
        assertFailure(result, stage: .recovery)
    }

    private func assertFailure(
        _ result: PersistentStoreBootstrapResult<Int>,
        stage: PersistentStoreBootstrapStage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failed(let failure) = result else {
            return XCTFail("Expected fail-closed storage", file: file, line: line)
        }
        XCTAssertEqual(failure.stage, stage, file: file, line: line)
    }
}
