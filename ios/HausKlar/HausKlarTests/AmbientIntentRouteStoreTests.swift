import Foundation
import XCTest

@testable import HausKlar

final class AmbientIntentRouteStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AmbientIntentRouteStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRouteCanOnlyBeTakenByItsOwnerAndIsConsumedOnce() throws {
        let route = try XCTUnwrap(
            HausKlarDeepLink(
                url: try XCTUnwrap(URL(string: "hausklar://calendar?event=event-1"))
            )
        )
        try AmbientIntentRouteStore.save(
            route,
            ownerIdentity: "family-a:user-a",
            defaults: defaults
        )

        XCTAssertNil(
            AmbientIntentRouteStore.take(
                activeIdentity: "family-b:user-b",
                defaults: defaults
            )
        )
        XCTAssertNil(
            AmbientIntentRouteStore.take(
                activeIdentity: "family-a:user-a",
                defaults: defaults
            )
        )
    }

    func testMatchingOwnerReceivesTypedRouteAndClearPurgesPendingState() throws {
        let route = try XCTUnwrap(
            HausKlarDeepLink(url: try XCTUnwrap(URL(string: "hausklar://capture?text=Milk")))
        )
        try AmbientIntentRouteStore.save(
            route,
            ownerIdentity: "family-a:user-a",
            defaults: defaults
        )

        XCTAssertEqual(
            AmbientIntentRouteStore.take(
                activeIdentity: "family-a:user-a",
                defaults: defaults
            ),
            route
        )

        try AmbientIntentRouteStore.save(
            route,
            ownerIdentity: "family-a:user-a",
            defaults: defaults
        )
        AmbientIntentRouteStore.clear(defaults: defaults)
        XCTAssertNil(
            AmbientIntentRouteStore.take(
                activeIdentity: "family-a:user-a",
                defaults: defaults
            )
        )
    }

    func testMalformedPayloadAndOversizedOwnerFailClosed() throws {
        defaults.set(Data("not-json".utf8), forKey: AmbientIntentRouteStore.key)
        XCTAssertNil(
            AmbientIntentRouteStore.take(
                activeIdentity: "family-a:user-a",
                defaults: defaults
            )
        )

        let route = try XCTUnwrap(
            HausKlarDeepLink(url: try XCTUnwrap(URL(string: "hausklar://today")))
        )
        XCTAssertThrowsError(
            try AmbientIntentRouteStore.save(
                route,
                ownerIdentity: String(repeating: "a", count: 321),
                defaults: defaults
            )
        )
    }

    func testConcurrentConsumersClaimEachPendingRouteExactlyOnce() throws {
        let localDefaults = try XCTUnwrap(defaults)
        let route = try XCTUnwrap(
            HausKlarDeepLink(
                url: try XCTUnwrap(URL(string: "hausklar://calendar?event=concurrent"))
            )
        )

        for _ in 0..<64 {
            try AmbientIntentRouteStore.save(
                route,
                ownerIdentity: "family-a:user-a",
                defaults: localDefaults
            )
            let results = AmbientRouteResults()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                results.append(
                    AmbientIntentRouteStore.take(
                        activeIdentity: "family-a:user-a",
                        defaults: localDefaults
                    )
                )
            }

            XCTAssertEqual(results.routes, [route])
        }
    }

    func testConcurrentSaveCannotBeRemovedByAnEarlierTake() throws {
        let localDefaults = try XCTUnwrap(defaults)
        let oldRoute = try XCTUnwrap(
            HausKlarDeepLink(
                url: try XCTUnwrap(URL(string: "hausklar://calendar?event=old"))
            )
        )
        let newRoute = try XCTUnwrap(
            HausKlarDeepLink(
                url: try XCTUnwrap(URL(string: "hausklar://calendar?event=new"))
            )
        )

        for _ in 0..<128 {
            try AmbientIntentRouteStore.save(
                oldRoute,
                ownerIdentity: "family-a:user-a",
                defaults: localDefaults
            )
            let results = AmbientRouteResults()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    results.append(
                        AmbientIntentRouteStore.take(
                            activeIdentity: "family-a:user-a",
                            defaults: localDefaults
                        )
                    )
                } else {
                    do {
                        try AmbientIntentRouteStore.save(
                            newRoute,
                            ownerIdentity: "family-a:user-a",
                            defaults: localDefaults
                        )
                    } catch {
                        results.append(error)
                    }
                }
            }

            XCTAssertTrue(results.errors.isEmpty, "Save failures: \(results.errors)")
            let consumed = try XCTUnwrap(results.routes.first)
            let remaining = AmbientIntentRouteStore.take(
                activeIdentity: "family-a:user-a",
                defaults: localDefaults
            )
            if consumed == oldRoute {
                XCTAssertEqual(remaining, newRoute)
            } else {
                XCTAssertEqual(consumed, newRoute)
                XCTAssertNil(remaining)
            }
        }
    }
}

private final class AmbientRouteResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRoutes: [HausKlarDeepLink] = []
    private var storedErrors: [Error] = []

    var routes: [HausKlarDeepLink] {
        lock.withLock { storedRoutes }
    }

    var errors: [Error] {
        lock.withLock { storedErrors }
    }

    func append(_ route: HausKlarDeepLink?) {
        guard let route else { return }
        lock.withLock { storedRoutes.append(route) }
    }

    func append(_ error: Error) {
        lock.withLock { storedErrors.append(error) }
    }
}
