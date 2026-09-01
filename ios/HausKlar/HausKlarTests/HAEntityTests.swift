import XCTest
@testable import HausKlar

final class HAEntityTests: XCTestCase {

    private func decodeEntity(from json: String) throws -> HAEntity {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(HAEntity.self, from: data)
    }

    func testDecodeClimateEntity() throws {
        let json = """
        {
            "entity_id": "climate.example_dfadd42f",
            "state": "heat",
            "attributes": {
                "friendly_name": "Living Room Thermostat",
                "current_temperature": 19.5,
                "temperature": 21.0,
                "hvac_action": "heating",
                "hvac_modes": ["off", "heat", "auto"]
            },
            "last_changed": "2026-02-20T08:30:00+00:00",
            "last_updated": "2026-02-20T08:31:00+00:00"
        }
        """

        let entity = try decodeEntity(from: json)

        XCTAssertEqual(entity.entityId, "climate.example_dfadd42f")
        XCTAssertEqual(entity.state, "heat")
        XCTAssertEqual(entity.currentTemperature, 19.5)
        XCTAssertEqual(entity.targetTemperature, 21.0)
        XCTAssertEqual(entity.hvacAction, "heating")
        XCTAssertEqual(entity.friendlyName, "Living Room Thermostat")
    }

    func testDecodeLightEntity() throws {
        let json = """
        {
            "entity_id": "light.example_d7ab5b9b",
            "state": "on",
            "attributes": {
                "friendly_name": "Hallway Light",
                "brightness": 178,
                "color_mode": "brightness",
                "supported_color_modes": ["brightness"]
            },
            "last_changed": "2026-02-20T19:00:00+00:00",
            "last_updated": "2026-02-20T19:00:01+00:00"
        }
        """

        let entity = try decodeEntity(from: json)

        XCTAssertTrue(entity.isOn)
        XCTAssertEqual(entity.brightness, 178)
        XCTAssertEqual(entity.domain, "light")
        XCTAssertEqual(entity.friendlyName, "Hallway Light")
    }

    func testDecodeBinarySensorEntity() throws {
        let json = """
        {
            "entity_id": "binary_sensor.example_e1938001_contact",
            "state": "off",
            "attributes": {
                "friendly_name": "Front Door",
                "device_class": "door"
            },
            "last_changed": "2026-02-20T07:15:00+00:00",
            "last_updated": "2026-02-20T07:15:00+00:00"
        }
        """

        let entity = try decodeEntity(from: json)

        XCTAssertEqual(entity.domain, "binary_sensor")
        XCTAssertFalse(entity.isOn)
        XCTAssertEqual(entity.friendlyName, "Front Door")
        XCTAssertEqual(entity.entityId, "binary_sensor.example_e1938001_contact")
    }

    func testDecodeMediaPlayerEntity() throws {
        let json = """
        {
            "entity_id": "media_player.example_0602377b",
            "state": "playing",
            "attributes": {
                "friendly_name": "Sonos Living Room",
                "media_title": "Bohemian Rhapsody",
                "media_artist": "Queen",
                "media_content_type": "music",
                "volume_level": 0.35
            },
            "last_changed": "2026-02-20T18:45:00+00:00",
            "last_updated": "2026-02-20T18:45:05+00:00"
        }
        """

        let entity = try decodeEntity(from: json)

        XCTAssertEqual(entity.mediaTitle, "Bohemian Rhapsody")
        XCTAssertEqual(entity.mediaArtist, "Queen")
        XCTAssertEqual(entity.domain, "media_player")
        XCTAssertEqual(entity.friendlyName, "Sonos Living Room")
    }

    func testDomainExtraction() throws {
        let json = """
        {
            "entity_id": "climate.example_dfadd42f",
            "state": "heat",
            "attributes": {},
            "last_changed": "2026-02-20T08:00:00+00:00",
            "last_updated": "2026-02-20T08:00:00+00:00"
        }
        """

        let entity = try decodeEntity(from: json)

        XCTAssertEqual(entity.domain, "climate")
    }

    func testFriendlyNameFromAttributes() throws {
        let json = """
        {
            "entity_id": "switch.bathroom_dehumidifier",
            "state": "off",
            "attributes": {
                "friendly_name": "Bathroom Dehumidifier"
            },
            "last_changed": "2026-02-20T10:00:00+00:00",
            "last_updated": "2026-02-20T10:00:00+00:00"
        }
        """

        let entity = try decodeEntity(from: json)

        XCTAssertEqual(entity.friendlyName, "Bathroom Dehumidifier")

        // Also verify fallback: when friendly_name is absent, entityId is used
        let jsonNoName = """
        {
            "entity_id": "switch.unnamed_plug",
            "state": "on",
            "attributes": {},
            "last_changed": "2026-02-20T10:00:00+00:00",
            "last_updated": "2026-02-20T10:00:00+00:00"
        }
        """

        let entityNoName = try decodeEntity(from: jsonNoName)

        XCTAssertEqual(entityNoName.friendlyName, "switch.unnamed_plug")
    }
}
