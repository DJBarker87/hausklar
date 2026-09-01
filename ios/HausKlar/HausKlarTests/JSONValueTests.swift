import XCTest
@testable import HausKlar

final class JSONValueTests: XCTestCase {

    private func decode(_ json: String) throws -> JSONValue {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testDecodeString() throws {
        let value = try decode("\"hello\"")

        XCTAssertEqual(value, .string("hello"))
        XCTAssertEqual(value.stringValue, "hello")
        XCTAssertNil(value.intValue)
        XCTAssertNil(value.doubleValue)
        XCTAssertNil(value.boolValue)
    }

    func testDecodeNumber() throws {
        let doubleValue = try decode("42.5")

        XCTAssertEqual(doubleValue, .double(42.5))
        XCTAssertEqual(doubleValue.doubleValue, 42.5)
        XCTAssertNil(doubleValue.stringValue)

        // Integer values decode as .int, not .double
        let intValue = try decode("42")

        XCTAssertEqual(intValue, .int(42))
        XCTAssertEqual(intValue.intValue, 42)
        // doubleValue should still work for .int (returns Double(value))
        XCTAssertEqual(intValue.doubleValue, 42.0)
    }

    func testDecodeBool() throws {
        let trueValue = try decode("true")

        XCTAssertEqual(trueValue, .bool(true))
        XCTAssertEqual(trueValue.boolValue, true)
        XCTAssertNil(trueValue.stringValue)
        XCTAssertNil(trueValue.intValue)

        let falseValue = try decode("false")

        XCTAssertEqual(falseValue, .bool(false))
        XCTAssertEqual(falseValue.boolValue, false)
    }

    func testDecodeNull() throws {
        let value = try decode("null")

        XCTAssertEqual(value, .null)
        XCTAssertNil(value.stringValue)
        XCTAssertNil(value.intValue)
        XCTAssertNil(value.doubleValue)
        XCTAssertNil(value.boolValue)
    }

    func testDecodeNestedObject() throws {
        let json = """
        {"key": "val", "count": 3}
        """

        let value = try decode(json)

        if case let .object(dict) = value {
            XCTAssertEqual(dict["key"], .string("val"))
            XCTAssertEqual(dict["count"], .int(3))
            XCTAssertEqual(dict["key"]?.stringValue, "val")
            XCTAssertEqual(dict["count"]?.intValue, 3)
        } else {
            XCTFail("Expected .object, got \(value)")
        }
    }
}
