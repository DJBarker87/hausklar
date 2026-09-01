import XCTest

@testable import HausKlar

final class HausKlarDeepLinkTests: XCTestCase {
    func testParsesEverySupportedExactRoute() throws {
        XCTAssertEqual(try parse("hausklar://today"), .today)
        XCTAssertEqual(
            try parse("hausklar://calendar?event=event-1"),
            .calendar(eventID: "event-1")
        )
        XCTAssertEqual(
            try parse("hausklar://medicine?child_id=child-1&medicine_type_id=medicine-1"),
            .medicine(childID: "child-1", medicineTypeID: "medicine-1")
        )
        XCTAssertEqual(
            try parse("hausklar://naps?nap_id=nap-1&child_id=child-1"),
            .naps(napID: "nap-1", childID: "child-1")
        )
        XCTAssertEqual(
            try parse("hausklar://star-chart?child_id=child-1&chart_id=chart-1"),
            .starChart(chartID: "chart-1", childID: "child-1")
        )
        XCTAssertEqual(
            try parse("hausklar://photos?asset_id=asset_1"),
            .photos(assetID: "asset_1")
        )
        XCTAssertEqual(try parse("hausklar://fitness/imports"), .fitnessImports)
        XCTAssertEqual(
            try parse("hausklar://fitness/withings?status=connected"),
            .fitnessWithings
        )
    }

    func testCaptureTextIsDecodedOnlyAfterBoundsAndCharacterChecks() throws {
        XCTAssertEqual(
            try parse("hausklar://capture?text=Buy%20milk"),
            .capture(text: "Buy milk")
        )
        XCTAssertNil(parseOptional("hausklar://capture?text="))
        XCTAssertNil(parseOptional("hausklar://capture?text=one%0Atwo"))
        let oversized = String(repeating: "a", count: 2_001)
        var components = URLComponents(string: "hausklar://capture")
        components?.queryItems = [URLQueryItem(name: "text", value: oversized)]
        XCTAssertNil(components?.url.flatMap(HausKlarDeepLink.init(url:)))
    }

    func testRejectsDuplicateUnexpectedAndPartialQueryContracts() {
        XCTAssertNil(parseOptional("hausklar://calendar?event=one&event=two"))
        XCTAssertNil(parseOptional("hausklar://calendar?event"))
        XCTAssertNil(parseOptional("hausklar://today?extra=1"))
        XCTAssertNil(parseOptional("hausklar://naps?nap_id=nap-1"))
        XCTAssertNil(parseOptional("hausklar://star-chart?child_id=child-1"))
        XCTAssertNil(parseOptional("hausklar://dog?activity_id=walk-1"))
        XCTAssertNil(parseOptional("hausklar://fitness/withings?status=unknown"))
    }

    func testRejectsStructuralAmbiguityAndMalformedIdentifiers() {
        XCTAssertNil(parseOptional("HAUSKLAR://today"))
        XCTAssertNil(parseOptional("hausklar://user:secret@today"))
        XCTAssertNil(parseOptional("hausklar://today:123"))
        XCTAssertNil(parseOptional("hausklar://today/path"))
        XCTAssertNil(parseOptional("hausklar://today#fragment"))
        XCTAssertNil(parseOptional("hausklar://calendar?event=../../secret"))
        XCTAssertNil(parseOptional("hausklar://calendar?event=%"))
        XCTAssertNil(parseOptional("https://example.com/today"))
        XCTAssertNil(parseOptional("hausklar://unknown"))
    }

    func testTypedRoutesRoundTripThroughCodableStorage() throws {
        let route = HausKlarDeepLink.medicine(childID: "child-1", medicineTypeID: "medicine-1")
        let data = try JSONEncoder().encode(route)
        XCTAssertEqual(try JSONDecoder().decode(HausKlarDeepLink.self, from: data), route)
    }

    private func parse(_ value: String) throws -> HausKlarDeepLink {
        let url = try XCTUnwrap(URL(string: value))
        return try XCTUnwrap(HausKlarDeepLink(url: url))
    }

    private func parseOptional(_ value: String) -> HausKlarDeepLink? {
        URL(string: value).flatMap(HausKlarDeepLink.init(url:))
    }
}
