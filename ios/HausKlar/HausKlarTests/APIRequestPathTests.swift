import XCTest

@testable import HausKlar

final class APIRequestPathTests: XCTestCase {
    func testInterpolatedSegmentUsesFiniteUnreservedEncoding() throws {
        let value = "Müller & Sons"
        let path: APIRequestPath = "/documents/\(value)/content"

        XCTAssertEqual(
            try path.validatedValue(),
            "/documents/M%C3%BCller%20%26%20Sons/content"
        )
    }

    func testReservedDynamicDelimitersFailClosed() {
        for value in ["another/route", "..", ".", "id?admin=true", "id#fragment", "id\\child"] {
            let path: APIRequestPath = "/documents/\(value)"
            XCTAssertThrowsError(try path.validatedValue(), value)
        }
    }

    func testControlPercentAndOversizedDynamicSegmentsFailClosed() {
        for value in ["line\nbreak", "already%2Fescaped", String(repeating: "a", count: 513)] {
            let path: APIRequestPath = "/documents/\(value)"
            XCTAssertThrowsError(try path.validatedValue(), value)
        }
    }

    func testStoredPathRejectsQueryFragmentTraversalAndEncodedDelimiters() {
        for value in [
            "/documents/id?download=true",
            "/documents/id#fragment",
            "/documents/../tasks",
            "/documents/%2E%2E/tasks",
            "/documents/a%2Fb",
            "/documents/a%5Cb",
            "/documents/a%3Fb",
            "/documents/a%23b",
            "//lookalike.example/documents",
        ] {
            XCTAssertThrowsError(try APIRequestPath.validateStoredValue(value), value)
        }
    }

    func testStoredPathRejectsMalformedEscapesAndExcessiveLength() {
        for value in ["/documents/%", "/documents/%2", "/documents/%GG"] {
            XCTAssertThrowsError(try APIRequestPath.validateStoredValue(value), value)
        }
        XCTAssertThrowsError(
            try APIRequestPath.validateStoredValue("/" + String(repeating: "a", count: 4_096))
        )
    }

    func testStaticTrailingSlashAndEncodedUnicodeRemainValid() throws {
        try APIRequestPath.validateStoredValue("/meals/")
        try APIRequestPath.validateStoredValue("/documents/M%C3%BCller")
    }
}
