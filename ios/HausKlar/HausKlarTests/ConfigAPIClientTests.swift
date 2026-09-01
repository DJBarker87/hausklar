import XCTest
@testable import HausKlar

@MainActor
final class ConfigAPIClientTests: XCTestCase {

    func testSharedInstanceExists() {
        XCTAssertNotNil(ConfigAPIClient.shared)
    }

    func testFallbackConfigReturnsRooms() {
        let config = ConfigAPIClient.shared.fallbackConfig()
        XCTAssertFalse(config.rooms.isEmpty)
    }

    func testFallbackConfigReturnsDevices() {
        let config = ConfigAPIClient.shared.fallbackConfig()
        XCTAssertFalse(config.devices.isEmpty)
    }

    func testFallbackRoomsHaveLabels() {
        let config = ConfigAPIClient.shared.fallbackConfig()
        for room in config.rooms {
            XCTAssertFalse(room.label.isEmpty, "Room \(room.id) has empty label")
        }
    }

    func testFallbackDevicesHaveEntityIds() {
        let config = ConfigAPIClient.shared.fallbackConfig()
        for device in config.devices {
            XCTAssertFalse(device.entityId.isEmpty, "Device \(device.id) has empty entityId")
        }
    }
}
