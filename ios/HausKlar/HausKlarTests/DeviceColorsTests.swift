import XCTest
@testable import HausKlar

final class DeviceColorsTests: XCTestCase {

    private func makeEntity(id: String = "test.entity", state: String, attributes: [String: JSONValue] = [:]) -> HAEntity {
        let now = ISODateParser.string(from: Date())
        return HAEntity(entityId: id, state: state, attributes: attributes, lastChanged: now, lastUpdated: now)
    }

    // MARK: - color(for:entity:) tests

    func testLightOnColor() {
        let entity = makeEntity(state: "on")
        let (_, opacity) = DeviceColors.color(for: "light", entity: entity)
        XCTAssertEqual(opacity, 0.60)
    }

    func testLightOffColor() {
        let entity = makeEntity(state: "off")
        let (_, opacity) = DeviceColors.color(for: "light", entity: entity)
        XCTAssertEqual(opacity, 0.35)
    }

    func testContactOpenColor() {
        let entity = makeEntity(state: "on")
        let (_, opacity) = DeviceColors.color(for: "contact", entity: entity)
        XCTAssertEqual(opacity, 0.70)
    }

    func testContactClosedColor() {
        let entity = makeEntity(state: "off")
        let (_, opacity) = DeviceColors.color(for: "contact", entity: entity)
        XCTAssertEqual(opacity, 0.35)
    }

    func testMotionActiveColor() {
        let entity = makeEntity(state: "on")
        let (_, opacity) = DeviceColors.color(for: "motion", entity: entity)
        XCTAssertEqual(opacity, 0.70)
    }

    func testMotionInactiveColor() {
        let entity = makeEntity(state: "off")
        let (_, opacity) = DeviceColors.color(for: "motion", entity: entity)
        XCTAssertEqual(opacity, 0.30)
    }

    func testTrvHeatingColor() {
        let entity = makeEntity(state: "heat", attributes: ["hvac_action": .string("heating")])
        let (_, opacity) = DeviceColors.color(for: "trv", entity: entity)
        XCTAssertEqual(opacity, 0.60)
    }

    func testTrvIdleColor() {
        let entity = makeEntity(state: "heat", attributes: ["hvac_action": .string("idle")])
        let (_, opacity) = DeviceColors.color(for: "trv", entity: entity)
        XCTAssertEqual(opacity, 0.60)
    }

    func testTrvOffColor() {
        let entity = makeEntity(state: "off", attributes: ["hvac_action": .string("off")])
        let (_, opacity) = DeviceColors.color(for: "trv", entity: entity)
        XCTAssertEqual(opacity, 0.25)
    }

    func testApplianceRunningColor() {
        let entity = makeEntity(state: "running")
        let (_, opacity) = DeviceColors.color(for: "appliance", entity: entity)
        XCTAssertEqual(opacity, 0.70)
    }

    func testApplianceOffColor() {
        let entity = makeEntity(state: "off")
        let (_, opacity) = DeviceColors.color(for: "appliance", entity: entity)
        XCTAssertEqual(opacity, 0.30)
    }

    func testNilEntityFallback() {
        let (_, opacity) = DeviceColors.color(for: "light", entity: nil)
        XCTAssertEqual(opacity, 0.35)
    }

    func testBoilerOnColor() {
        let entity = makeEntity(state: "on")
        let (_, opacity) = DeviceColors.color(for: "boiler", entity: entity)
        XCTAssertEqual(opacity, 0.70)
    }

    func testUnknownTypeFallback() {
        let entity = makeEntity(state: "on")
        let (_, opacity) = DeviceColors.color(for: "unknown", entity: entity)
        XCTAssertEqual(opacity, 0.35)
    }
}
