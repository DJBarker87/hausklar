import XCTest
@testable import HausKlar

@MainActor
final class HAClientTests: XCTestCase {

    var client: HAClient!

    override func setUp() async throws {
        client = HAClient.shared
        client.reset()
    }

    override func tearDown() async throws {
        client.reset()
    }

    private func decodeSnapshot(_ json: String) throws -> HomeSnapshotDTO {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HomeSnapshotDTO.self, from: Data(json.utf8))
    }

    // MARK: - Configuration

    func testNotConfiguredInitially() {
        XCTAssertFalse(client.isConfigured)
    }

    func testBackendConfigurationStatusDoesNotRequireCredentials() {
        client.setBackendConfigured(true)
        XCTAssertTrue(client.isConfigured)
    }

    func testResetClearsBackendConfigurationStatus() {
        client.setBackendConfigured(true)
        client.reset()
        XCTAssertFalse(client.isConfigured)
    }

    func testBackendSnapshotDecodesIntoExistingEntityModel() throws {
        let data = Data(
            #"""
            {
              "configured": true,
              "available": true,
              "entities": [{
                "entity_id": "climate.example_9feafd80",
                "name": "Kitchen",
                "domain": "climate",
                "state": "heat",
                "current_temperature": 19.5,
                "temperature": 21.0,
                "hvac_action": "heating",
                "hvac_modes": ["off", "heat"],
                "last_changed": "2026-07-11T08:00:00Z",
                "last_updated": "2026-07-11T08:01:00Z"
              }]
            }
            """#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let snapshot = try decoder.decode(HomeSnapshotDTO.self, from: data)
        let entity = try XCTUnwrap(snapshot.entities.first?.asEntity())

        XCTAssertTrue(snapshot.configured)
        XCTAssertTrue(snapshot.available)
        XCTAssertEqual(entity.entityId, "climate.example_9feafd80")
        XCTAssertEqual(entity.friendlyName, "Kitchen")
        XCTAssertEqual(entity.currentTemperature, 19.5)
        XCTAssertEqual(entity.targetTemperature, 21.0)
        XCTAssertEqual(entity.hvacModes, ["off", "heat"])
    }

    func testTemperatureHistoryContractDecodesOnlyTheBoundedRoomSeries() throws {
        let data = Data(
            #"{"entity_id":"climate.example_9feafd80","unit":"°C","hours":24,"points":[{"recorded_at":"2026-08-15T07:00:00Z","temperature":20.5,"target_temperature":21.0,"heating":true}]}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let history = try decoder.decode(HomeTemperatureHistoryDTO.self, from: data)

        XCTAssertEqual(history.entityId, "climate.example_9feafd80")
        XCTAssertEqual(history.hours, 24)
        XCTAssertEqual(history.points.first?.temperature, 20.5)
        XCTAssertEqual(history.points.first?.targetTemperature, 21.0)
        XCTAssertEqual(history.points.first?.heating, true)
    }

    func testTemperatureHistoryEntityIDsCannotEscapeTheBackendPath() {
        XCTAssertTrue(HAClient.validEntityID("climate.example_9feafd80"))
        XCTAssertTrue(HAClient.validEntityID("sensor.bathroom_temperature"))
        XCTAssertFalse(HAClient.validEntityID("climate.example_9feafd80/../../secrets"))
        XCTAssertFalse(HAClient.validEntityID("Climate.Kitchen"))
    }

    func testLiveSnapshotCarriesServerOwnedManifestAndSitrep() throws {
        let snapshot = try decodeSnapshot(
            #"""
            {
              "configured": true,
              "available": true,
              "entities": [{
                "entity_id": "light.example_3f2a461f",
                "name": "Kitchen lights",
                "state": "on"
              }],
              "manifest": {
                "rooms": [{
                  "id": "kitchen",
                  "name": "Kitchen",
                  "floor": 0,
                  "entity_ids": ["light.example_3f2a461f"],
                  "light_entity_ids": ["light.example_3f2a461f"]
                }],
                "entities": [{
                  "entity_id": "light.example_3f2a461f",
                  "name": "Kitchen lights",
                  "domain": "light",
                  "room_id": "kitchen",
                  "room_name": "Kitchen",
                  "control_kind": "light",
                  "capabilities": ["toggle", "brightness"],
                  "favourite": true,
                  "advanced": false
                }],
                "favourite_entity_ids": ["light.example_3f2a461f"],
                "mode_selector": {
                  "entity_id": "input_select.house_mode",
                  "name": "House mode",
                  "current": "Home",
                  "options": ["Home", "Away"]
                },
                "broad_action_scopes": ["favourites", "room", "all"],
                "advanced_features": ["floor_plan_2d", "diagnostics"]
              },
              "sitrep": {
                "tone": "attention",
                "headline": "Front door is open",
                "summary": "One thing needs attention.",
                "exceptions": [{
                  "id": "binary_sensor.example_e1938001:open",
                  "severity": "attention",
                  "title": "Front door is open",
                  "detail": "Open now",
                  "entity_id": "binary_sensor.example_e1938001",
                  "room_id": "hallway"
                }],
                "updated_at": "2026-08-09T10:00:00Z"
              }
            }
            """#
        )

        try client.apply(snapshot: snapshot)

        XCTAssertEqual(client.manifest?.rooms.first?.name, "Kitchen")
        XCTAssertEqual(client.manifest?.favouriteEntityIds, ["light.example_3f2a461f"])
        XCTAssertEqual(client.manifest?.modeSelector?.options, ["Home", "Away"])
        XCTAssertEqual(client.sitrep?.headline, "Front door is open")
        XCTAssertEqual(client.sitrep?.exceptions.first?.entityId, "binary_sensor.example_e1938001")
    }

    func testLiveSnapshotReplacesDisplayedStateWithRealEntities() throws {
        client.loadDemoData()
        let snapshot = try decodeSnapshot(
            #"{"configured":true,"available":true,"entities":[{"entity_id":"light.real_hall","name":"Real Hall","state":"off"}]}"#
        )

        try client.apply(snapshot: snapshot)

        XCTAssertTrue(client.isConfigured)
        XCTAssertTrue(client.isConnected)
        XCTAssertFalse(client.isDemoMode)
        XCTAssertEqual(client.entities.count, 1)
        XCTAssertEqual(client.entity("light.real_hall")?.friendlyName, "Real Hall")
        XCTAssertNil(client.entity("light.example_d7ab5b9b"))
    }

    func testUnavailableConfiguredSnapshotPreservesLastRealState() throws {
        let liveSnapshot = try decodeSnapshot(
            #"{"configured":true,"available":true,"entities":[{"entity_id":"binary_sensor.example_e1938001","name":"Front Door","state":"on"}]}"#
        )
        try client.apply(snapshot: liveSnapshot)
        let lastRealEntity = try XCTUnwrap(client.entity("binary_sensor.example_e1938001"))
        let unavailableSnapshot = try decodeSnapshot(
            #"{"configured":true,"available":false,"entities":[]}"#
        )

        XCTAssertThrowsError(try client.apply(snapshot: unavailableSnapshot)) { error in
            guard case HAClientError.unavailable = error else {
                return XCTFail("Expected unavailable, got \(error)")
            }
        }

        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(client.isDemoMode)
        XCTAssertEqual(client.entity("binary_sensor.example_e1938001"), lastRealEntity)
        XCTAssertNil(client.entity("light.example_d7ab5b9b"))
    }

    func testUnconfiguredSnapshotNeverCreatesDemoState() throws {
        let snapshot = try decodeSnapshot(
            #"{"configured":false,"available":false,"entities":[]}"#
        )

        XCTAssertThrowsError(try client.apply(snapshot: snapshot)) { error in
            guard case HAClientError.notConfigured = error else {
                return XCTFail("Expected not configured, got \(error)")
            }
        }

        XCTAssertFalse(client.isConfigured)
        XCTAssertFalse(client.isDemoMode)
        XCTAssertTrue(client.entities.isEmpty)
    }

    func testServiceRequestUsesBackendEnvelopeWithoutCredentials() throws {
        let request = try HAClient.serviceRequest(
            domain: "light",
            service: "turn_on",
            data: ["entity_id": "light.example_3f2a461f", "brightness": 128],
            returnResponse: false
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["data"] as? [String: Any])

        XCTAssertEqual(object["domain"] as? String, "light")
        XCTAssertEqual(object["service"] as? String, "turn_on")
        XCTAssertEqual(object["return_response"] as? Bool, false)
        XCTAssertEqual(payload["entity_id"] as? String, "light.example_3f2a461f")
        XCTAssertEqual(payload["brightness"] as? Int, 128)
        XCTAssertNil(object["ha_url"])
        XCTAssertNil(object["ha_token"])
        XCTAssertNil(object["token"])
    }

    func testReturnResponseServiceRequestSetsBackendFlag() throws {
        let request = try HAClient.serviceRequest(
            domain: "media_player",
            service: "browse_media",
            data: ["entity_id": "media_player.example_47265f35"],
            returnResponse: true
        )

        XCTAssertTrue(request.returnResponse)
    }

    func testSettingsResponseUsesTokenConfiguredWithoutDecodingToken() throws {
        let data = Data(
            #"{"dashboard_url":null,"ha_url":"https://ha.example","config_api_url":null,"token_configured":true,"configured":true}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(HASettingsResponse.self, from: data)

        XCTAssertTrue(response.tokenConfigured)
        XCTAssertTrue(response.configured)
    }

    func testLegacyHomeAssistantCredentialsAreDeletedFromKeychain() {
        var deletedKeys: [String] = []

        KeychainManager.deleteLegacyHomeAssistantCredentials { key in
            deletedKeys.append(key)
            return true
        }

        XCTAssertEqual(Set(deletedKeys), [
            "org.example.hausklar.haURL",
            "org.example.hausklar.haToken",
        ])
    }

    // MARK: - Entity lookup

    func testEntityReturnsNilWhenEmpty() {
        XCTAssertNil(client.entity("light.example_d7ab5b9b"))
    }

    func testEntityReturnsAfterLoadDemoData() {
        client.loadDemoData()
        let entity = client.entity("light.example_d7ab5b9b")
        XCTAssertNotNil(entity)
        XCTAssertEqual(entity?.entityId, "light.example_d7ab5b9b")
    }

    func testEntitiesInDomainFiltersCorrectly() {
        client.loadDemoData()
        let lights = client.entities(inDomain: "light")
        XCTAssertTrue(lights.allSatisfy { $0.domain == "light" })
        XCTAssertFalse(lights.isEmpty)
    }

    func testEntitiesInDomainSortsByEntityId() {
        client.loadDemoData()
        let lights = client.entities(inDomain: "light")
        let ids = lights.map { $0.entityId }
        XCTAssertEqual(ids, ids.sorted())
    }

    // MARK: - Explicit demo data

    func testLoadDemoDataPopulatesEntities() {
        XCTAssertTrue(client.entities.isEmpty)
        client.loadDemoData()
        XCTAssertFalse(client.entities.isEmpty)
        XCTAssertTrue(client.isDemoMode)
        XCTAssertFalse(client.isConfigured)
    }

    func testLoadDemoDataIncludesClimate() {
        client.loadDemoData()
        let climates = client.entities(inDomain: "climate")
        XCTAssertFalse(climates.isEmpty)
    }

    func testLoadDemoDataIncludesLights() {
        client.loadDemoData()
        let lights = client.entities(inDomain: "light")
        XCTAssertFalse(lights.isEmpty)
    }

    func testLoadDemoDataIncludesDoors() {
        client.loadDemoData()
        let doors = client.entities(inDomain: "binary_sensor")
        XCTAssertFalse(doors.isEmpty)
    }

    func testLoadDemoDataIncludesSonos() {
        client.loadDemoData()
        let players = client.entities(inDomain: "media_player")
        XCTAssertFalse(players.isEmpty)
    }

    func testLoadDemoDataIncludesScenes() {
        client.loadDemoData()
        let scenes = client.entities(inDomain: "scene")
        XCTAssertFalse(scenes.isEmpty)
    }

    func testLoadDemoDataSetsConnectedFalse() {
        client.loadDemoData()
        XCTAssertFalse(client.isConnected)
    }

    // MARK: - Optimistic updates

    func testOptimisticStateUpdate() {
        client.loadDemoData()
        let entityId = "light.example_d7ab5b9b"
        XCTAssertEqual(client.entity(entityId)?.state, "on")
        client.updateEntityOptimistically(entityId, state: "off")
        XCTAssertEqual(client.entity(entityId)?.state, "off")
    }

    func testOptimisticAttributeUpdate() {
        client.loadDemoData()
        let entityId = "light.example_d7ab5b9b"
        client.updateEntityOptimistically(entityId, attributeUpdates: ["brightness": .int(100)])
        XCTAssertEqual(client.entity(entityId)?.brightness, 100)
    }

    func testOptimisticUpdateIgnoresMissingEntity() {
        client.loadDemoData()
        // Should not crash when entity doesn't exist
        client.updateEntityOptimistically("light.nonexistent", state: "on")
        XCTAssertNil(client.entity("light.nonexistent"))
    }
}
