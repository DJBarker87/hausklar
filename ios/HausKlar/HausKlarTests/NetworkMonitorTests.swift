import XCTest
@testable import HausKlar

private final class FakeNetworkPathSource: NetworkPathSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var receive: (@Sendable (NetworkPathSnapshot) -> Void)?

    func start(receive: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        startCount += 1
        self.receive = receive
    }

    func stop() {
        stopCount += 1
        receive = nil
    }

    func send(_ snapshot: NetworkPathSnapshot) {
        receive?(snapshot)
    }
}

@MainActor
final class NetworkMonitorTests: XCTestCase {
    func testInitialStateIsUnknownAndConservativelyDisconnected() {
        let monitor = NetworkMonitor(source: FakeNetworkPathSource())

        XCTAssertEqual(monitor.connectionState, .unknown)
        XCTAssertFalse(monitor.isConnected)
        XCTAssertNil(monitor.pathIdentity)
    }

    func testPathUpdatesPublishReachability() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()

        source.send(
            NetworkPathSnapshot(
                isSatisfied: true,
                activeInterfaceTypes: ["wifi"],
                availableInterfaces: ["wifi:en0"]
            )
        )
        await Task.yield()

        XCTAssertEqual(monitor.connectionState, .connected)
        XCTAssertTrue(monitor.isConnected)
        XCTAssertEqual(monitor.pathIdentity?.activeInterfaceTypes, ["wifi"])

        source.send(NetworkPathSnapshot(isSatisfied: false, activeInterfaceTypes: []))
        await Task.yield()
        XCTAssertEqual(monitor.connectionState, .disconnected)
        XCTAssertFalse(monitor.isConnected)
    }

    func testInterfaceOnlyChangeUpdatesPathIdentity() async {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)
        monitor.start()
        source.send(
            NetworkPathSnapshot(
                isSatisfied: true,
                activeInterfaceTypes: ["wifi"],
                availableInterfaces: ["wifi:en0", "cellular:pdp_ip0"]
            )
        )
        await Task.yield()
        let first = monitor.pathIdentity

        source.send(
            NetworkPathSnapshot(
                isSatisfied: true,
                activeInterfaceTypes: ["cellular"],
                availableInterfaces: ["wifi:en0", "cellular:pdp_ip0"],
                isConstrained: true
            )
        )
        await Task.yield()

        XCTAssertTrue(monitor.isConnected)
        XCTAssertNotEqual(monitor.pathIdentity, first)
        XCTAssertEqual(monitor.pathIdentity?.activeInterfaceTypes, ["cellular"])
        XCTAssertEqual(monitor.pathIdentity?.isConstrained, true)
    }

    func testStartIsIdempotentAndStopReturnsToUnknown() {
        let source = FakeNetworkPathSource()
        let monitor = NetworkMonitor(source: source)

        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()

        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 1)
        XCTAssertEqual(monitor.connectionState, .unknown)
        XCTAssertFalse(monitor.isConnected)
    }
}
