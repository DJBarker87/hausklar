import Foundation
import Network

enum NetworkConnectionState: Equatable {
    case unknown
    case connected
    case disconnected
}

/// A value snapshot keeps `NWPath` out of application logic and gives tests a
/// deterministic injection seam for interface-only transitions.
struct NetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    let activeInterfaceTypes: [String]
    let availableInterfaces: [String]
    let isExpensive: Bool
    let isConstrained: Bool

    init(
        isSatisfied: Bool,
        activeInterfaceTypes: [String],
        availableInterfaces: [String] = [],
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.isSatisfied = isSatisfied
        self.activeInterfaceTypes = Array(Set(activeInterfaceTypes)).sorted()
        self.availableInterfaces = Array(Set(availableInterfaces)).sorted()
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
}

protocol NetworkPathSource: AnyObject {
    func start(receive: @escaping @Sendable (NetworkPathSnapshot) -> Void)
    func stop()
}

final class SystemNetworkPathSource: NetworkPathSource {
    private let queue = DispatchQueue(label: "org.example.hausklar.networkmonitor")
    private var monitor: NWPathMonitor?

    func start(receive: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        // NWPathMonitor instances cannot be restarted after cancellation.
        // Create a fresh monitor so an explicit stop/start lifecycle remains valid.
        let monitor = NWPathMonitor()
        self.monitor?.cancel()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            let availableInterfaces = path.availableInterfaces.map { interface in
                "\(String(describing: interface.type)):\(interface.name)"
            }
            let knownTypes: [(NWInterface.InterfaceType, String)] = [
                (.wifi, "wifi"),
                (.cellular, "cellular"),
                (.wiredEthernet, "wiredEthernet"),
                (.loopback, "loopback"),
                (.other, "other"),
            ]
            receive(
                NetworkPathSnapshot(
                    isSatisfied: path.status == .satisfied,
                    activeInterfaceTypes: knownTypes.compactMap {
                        path.usesInterfaceType($0.0) ? $0.1 : nil
                    },
                    availableInterfaces: availableInterfaces,
                    isExpensive: path.isExpensive,
                    isConstrained: path.isConstrained
                )
            )
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

/// Publishes reachability based only on Apple's path monitor. It deliberately
/// does not probe a private host: path availability and HausKlar API
/// availability are separate signals, and an HTTP LAN probe leaks topology and
/// produces stale answers when Wi-Fi interfaces change while still connected.
@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var connectionState: NetworkConnectionState = .unknown
    @Published private(set) var isConnected = false
    @Published private(set) var pathIdentity: NetworkPathSnapshot?

    private let source: NetworkPathSource
    private var started = false
    private var generation: UInt64 = 0

    init(source: NetworkPathSource = SystemNetworkPathSource()) {
        self.source = source
    }

    func start() {
        guard !started else { return }
        started = true
        generation &+= 1
        let expectedGeneration = generation
        source.start { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self,
                      self.started,
                      self.generation == expectedGeneration else { return }
                self.apply(snapshot)
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        generation &+= 1
        source.stop()
        connectionState = .unknown
        isConnected = false
        pathIdentity = nil
    }

    private func apply(_ snapshot: NetworkPathSnapshot) {
        // Always publish a changed path identity, even when reachability stays
        // satisfied (for example Wi-Fi to Ethernet, or a constrained-path
        // transition). Consumers can react without a private-host probe.
        pathIdentity = snapshot
        connectionState = snapshot.isSatisfied ? .connected : .disconnected
        isConnected = snapshot.isSatisfied
    }
}
