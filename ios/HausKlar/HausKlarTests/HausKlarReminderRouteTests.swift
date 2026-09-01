import XCTest

@testable import HausKlar

final class HausKlarReminderRouteTests: XCTestCase {
    func testParsesSupportedReminderRoutes() {
        XCTAssertEqual(HausKlarReminderRoute(value: "/?view=today"), .today)
        XCTAssertEqual(
            HausKlarReminderRoute(value: "/?view=calendar&event=event-1"),
            .calendar(eventID: "event-1")
        )
        XCTAssertEqual(
            HausKlarReminderRoute(value: "/?view=lists&section=renewals&renewal=renewal-1"),
            .renewals(renewalID: "renewal-1")
        )
        XCTAssertEqual(
            HausKlarReminderRoute(value: "/?view=lists&section=renewals&library=loan-1"),
            .library(loanID: "loan-1")
        )
        XCTAssertEqual(
            HausKlarReminderRoute(value: "/?view=family&section=naps&child=child-1&nap=nap-1"),
            .naps(napID: "nap-1", childID: "child-1")
        )
    }

    func testKnownWebOnlyShapesPreserveTodayFallback() {
        XCTAssertEqual(
            HausKlarReminderRoute(
                value: "/?view=finance&section=coach&action=payday-action&scope=household"
            ),
            .today
        )
        XCTAssertEqual(
            HausKlarReminderRoute(value: "/?view=documents&document=push-doc"),
            .today
        )
    }

    func testRejectsUnknownDuplicatePartialAndUnboundedPayloads() {
        let invalid = [
            "/?view=unknown",
            "/?view=today&view=calendar",
            "/?view=calendar&event=../../secret",
            "/?view=family&section=naps&nap=nap-1",
            "/?view=lists&section=meals&task=unexpected",
            "/?view=lists&section=renewals&library=loan-1&renewal=renewal-1",
            "/?view=lists&section=renewals&library=",
            "https://example.com/?view=today",
            "/path?view=today",
            "/?view=today#fragment",
            "/?view=today%0A",
        ]
        for value in invalid {
            XCTAssertNil(HausKlarReminderRoute(value: value), value)
        }
        XCTAssertNil(
            HausKlarReminderRoute(value: "/?view=calendar&event=" + String(repeating: "a", count: 161))
        )
    }
}
