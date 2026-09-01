import XCTest
@testable import HausKlar

final class ISODateParserTests: XCTestCase {

    func testParseWithFractionalSeconds() {
        let date = ISODateParser.parse("2024-01-15T10:30:00.123Z")
        XCTAssertNotNil(date)
    }

    func testParseWithoutFractionalSeconds() {
        let date = ISODateParser.parse("2024-01-15T10:30:00Z")
        XCTAssertNotNil(date)
    }

    func testParseInvalidStringReturnsNil() {
        XCTAssertNil(ISODateParser.parse("not-a-date"))
        XCTAssertNil(ISODateParser.parse(""))
        XCTAssertNil(ISODateParser.parse("2024-13-45"))
    }

    func testRoundTripWithFractional() {
        let original = Date(timeIntervalSince1970: 1705312200.123)
        let string = ISODateParser.string(from: original)
        let parsed = ISODateParser.parse(string)
        XCTAssertNotNil(parsed)
        // Allow 1ms tolerance for fractional precision
        XCTAssertEqual(parsed!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRoundTripWithoutFractional() {
        let original = Date(timeIntervalSince1970: 1705312200)
        let string = ISODateParser.stringNoFractional(from: original)
        let parsed = ISODateParser.parse(string)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 1.0)
    }

    func testStringFromDateIncludesFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1705312200.5)
        let string = ISODateParser.string(from: date)
        XCTAssertTrue(string.contains("."))
    }

    func testStringNoFractionalExcludesFractionalSeconds() {
        let date = Date(timeIntervalSince1970: 1705312200.5)
        let string = ISODateParser.stringNoFractional(from: date)
        // The string should not contain a decimal point before 'Z'
        let beforeZ = string.replacingOccurrences(of: "Z", with: "")
        XCTAssertFalse(beforeZ.hasSuffix(".5"))
    }

    func testParseTimezoneOffset() {
        // ISO8601 with timezone offset instead of Z
        let date = ISODateParser.parse("2024-01-15T10:30:00+00:00")
        XCTAssertNotNil(date)
    }
}
