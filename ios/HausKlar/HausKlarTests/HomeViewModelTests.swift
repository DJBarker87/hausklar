import XCTest
@testable import HausKlar

@MainActor
final class HomeViewModelTests: XCTestCase {

    var vm: HomeViewModel!

    override func setUp() async throws {
        HAClient.shared.reset()
        vm = HomeViewModel(explicitDemoMode: true)
        // Clean scene favorites
        UserDefaults.standard.removeObject(forKey: "favorite_scenes")
        UserDefaults.standard.removeObject(forKey: "cachedEntityStates")
        UserDefaults.standard.removeObject(forKey: "cachedEntityTimestamp")
        UserDefaults.standard.removeObject(forKey: "cachedHomeManifest")
        UserDefaults.standard.removeObject(forKey: "cachedHomeSitrep")
    }

    override func tearDown() async throws {
        HAClient.shared.reset()
        UserDefaults.standard.removeObject(forKey: "favorite_scenes")
        UserDefaults.standard.removeObject(forKey: "cachedEntityStates")
        UserDefaults.standard.removeObject(forKey: "cachedEntityTimestamp")
        UserDefaults.standard.removeObject(forKey: "cachedHomeManifest")
        UserDefaults.standard.removeObject(forKey: "cachedHomeSitrep")
    }

    // MARK: - Helpers

    private var now: String {
        ISODateParser.string(from: Date())
    }

    private func makeEntity(id: String, state: String, attrs: [String: JSONValue] = [:]) -> HAEntity {
        HAEntity(entityId: id, state: state, attributes: attrs, lastChanged: now, lastUpdated: now)
    }

    private func decodeSnapshot(_ json: String) throws -> HomeSnapshotDTO {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(HomeSnapshotDTO.self, from: Data(json.utf8))
    }

    func testProtectedHomeSnapshotStoreIsIdentityScopedAndPurgeable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HausKlarHomeSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = ProtectionRecordingFileManager()
        let store = HomeSnapshotStore(directory: directory, fileManager: fileManager)
        let entity = makeEntity(id: "light.private", state: "on")
        let snapshot = HomeOfflineSnapshot(
            entities: [entity.entityId: entity],
            fetchedAt: Date(timeIntervalSince1970: 1234),
            manifest: nil,
            sitrep: nil
        )

        await store.activate(identity: "family-a:a")
        let optionalAccountALease = await store.lease(identity: "family-a:a")
        let accountALease = try XCTUnwrap(optionalAccountALease)
        try await store.save(snapshot, lease: accountALease)
        await store.activate(identity: "family-b:b")
        let optionalAccountBLease = await store.lease(identity: "family-b:b")
        let accountBLease = try XCTUnwrap(optionalAccountBLease)
        try await store.save(snapshot, lease: accountBLease)

        await store.activate(identity: "family-a:a")
        let accountA = try await store.load(identity: "family-a:a")
        await store.activate(identity: "family-b:b")
        let accountB = try await store.load(identity: "family-b:b")
        let accountAFile = await store.fileURL(identity: "family-a:a")
        let accountBFile = await store.fileURL(identity: "family-b:b")
        XCTAssertEqual(accountA, snapshot)
        XCTAssertEqual(accountB, snapshot)
        XCTAssertNotEqual(accountAFile, accountBFile)
        XCTAssertEqual(
            fileManager.protection(atPath: directory.path),
            FileProtectionType.complete.rawValue
        )
        XCTAssertEqual(
            fileManager.protection(atPath: accountAFile.path),
            FileProtectionType.complete.rawValue
        )
#if targetEnvironment(simulator)
        // The simulator does not expose the persisted Data Protection key. The
        // injected recorder above observes the successful setAttributes call;
        // device runs additionally verify the filesystem's reported value.
        XCTAssertTrue(FileManager.default.fileExists(atPath: accountAFile.path))
#else
        let attributes = try FileManager.default.attributesOfItem(
            atPath: accountAFile.path
        )
        XCTAssertEqual(
            attributes[.protectionKey] as? String,
            FileProtectionType.complete.rawValue
        )
#endif

        try await store.securePurge()
        let purgedA = try await store.load(identity: "family-a:a")
        let purgedB = try await store.load(identity: "family-b:b")
        XCTAssertNil(purgedA)
        XCTAssertNil(purgedB)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountAFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountBFile.path))
        do {
            try await store.save(snapshot, lease: accountBLease)
            XCTFail("A pre-purge Home lease must not recreate private files")
        } catch APIError.unauthorized {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountBFile.path))
    }

    func testHomeSnapshotStoreRejectsSymlinkAndOversizedFilesBeforeDecode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HausKlarHomeSnapshotBounds-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = HomeSnapshotStore(directory: directory)
        let identity = "family-a:a"
        await store.activate(identity: identity)
        let file = await store.fileURL(identity: identity)
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        do {
            _ = try await store.load(identity: identity)
            XCTFail("An identity snapshot symlink must be rejected")
        } catch HomeSnapshotStoreError.invalidFile {
            // Expected.
        }

        try FileManager.default.removeItem(at: file)
        try Data(count: HomeSnapshotStore.maximumSnapshotBytes + 1).write(to: file)
        do {
            _ = try await store.load(identity: identity)
            XCTFail("An oversized snapshot must be rejected before mapped decoding")
        } catch HomeSnapshotStoreError.invalidFile {
            // Expected.
        }
    }

    func testHomeSnapshotStoreRefusesOversizedEncodedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HausKlarHomeSnapshotSaveCap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomeSnapshotStore(directory: directory)
        let identity = "family-a:a"
        await store.activate(identity: identity)
        let optionalLease = await store.lease(identity: identity)
        let lease = try XCTUnwrap(optionalLease)
        let entity = makeEntity(
            id: "sensor.large",
            state: "ok",
            attrs: [
                "payload": .string(
                    String(repeating: "x", count: HomeSnapshotStore.maximumSnapshotBytes + 1)
                )
            ]
        )
        let snapshot = HomeOfflineSnapshot(
            entities: [entity.entityId: entity],
            fetchedAt: Date(),
            manifest: nil,
            sitrep: nil
        )

        do {
            try await store.save(snapshot, lease: lease)
            XCTFail("Oversized Home snapshots must never be written")
        } catch HomeSnapshotStoreError.snapshotTooLarge {
            // Expected.
        }
        let file = await store.fileURL(identity: identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLegacyHomeSnapshotMigratesOnlyForMatchingOwner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HausKlarHomeSnapshotMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomeSnapshotStore(directory: directory)
        await store.activate(identity: "family-a:a")
        let entity = makeEntity(id: "light.legacy", state: "on")
        UserDefaults.standard.set(
            try JSONEncoder().encode([entity.entityId: entity]),
            forKey: HomeSnapshotCacheKeys.states
        )
        UserDefaults.standard.set(
            Date(timeIntervalSince1970: 4321).timeIntervalSince1970,
            forKey: HomeSnapshotCacheKeys.timestamp
        )
        UserDefaults.standard.set("family-a:a", forKey: AppState.localOwnerKey)
        defer { UserDefaults.standard.removeObject(forKey: AppState.localOwnerKey) }
        vm = HomeViewModel(
            explicitDemoMode: false,
            snapshotStore: store,
            cacheIdentity: { "family-a:a" }
        )

        await vm.loadCachedState()

        XCTAssertEqual(HAClient.shared.entity(entity.entityId), entity)
        let migrated = try await store.load(identity: "family-a:a")
        XCTAssertEqual(migrated?.entities[entity.entityId], entity)
        for key in HomeSnapshotCacheKeys.all {
            XCTAssertNil(UserDefaults.standard.object(forKey: key))
        }
    }

    func testLegacyHomeSnapshotFromDifferentOwnerIsPurgedNotMigrated() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HausKlarHomeSnapshotWrongOwner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomeSnapshotStore(directory: directory)
        await store.activate(identity: "family-b:b")
        let entity = makeEntity(id: "light.account_a", state: "on")
        UserDefaults.standard.set(
            try JSONEncoder().encode([entity.entityId: entity]),
            forKey: HomeSnapshotCacheKeys.states
        )
        UserDefaults.standard.set("family-a:a", forKey: AppState.localOwnerKey)
        defer { UserDefaults.standard.removeObject(forKey: AppState.localOwnerKey) }
        vm = HomeViewModel(
            explicitDemoMode: false,
            snapshotStore: store,
            cacheIdentity: { "family-b:b" }
        )

        await vm.loadCachedState()

        XCTAssertNil(HAClient.shared.entity(entity.entityId))
        let migrated = try await store.load(identity: "family-b:b")
        XCTAssertNil(migrated)
        for key in HomeSnapshotCacheKeys.all {
            XCTAssertNil(UserDefaults.standard.object(forKey: key))
        }
    }

    // MARK: - Truth states

    func testExplicitDemoIsUnmistakableAndPopulated() async {
        await vm.refresh()

        XCTAssertEqual(vm.presentationState, .demo)
        XCTAssertTrue(vm.isDemoMode)
        XCTAssertTrue(vm.isMockData)
        XCTAssertFalse(HAClient.shared.entities.isEmpty)
        XCTAssertTrue(vm.canPerformActions)
    }

    func testSuccessfulRefreshPresentsLiveRealState() async throws {
        HAClient.shared.reset()
        HAClient.shared.setBackendConfigured(true)
        let snapshot = try decodeSnapshot(
            #"{"configured":true,"available":true,"entities":[{"entity_id":"light.real_kitchen","name":"Real Kitchen","state":"on"}]}"#
        )
        vm = HomeViewModel(explicitDemoMode: false, fetchStates: {
            try HAClient.shared.apply(snapshot: snapshot)
        })
        vm.isConfigured = true

        await vm.refresh()

        XCTAssertEqual(vm.presentationState, .live)
        XCTAssertFalse(vm.isDemoMode)
        XCTAssertEqual(HAClient.shared.entity("light.real_kitchen")?.friendlyName, "Real Kitchen")
        XCTAssertNil(HAClient.shared.entity("light.example_d7ab5b9b"))
        XCTAssertTrue(vm.canPerformActions)
    }

    func testConfiguredFailureKeepsLastRealStateWithoutDemo() async {
        HAClient.shared.reset()
        HAClient.shared.setBackendConfigured(true)
        let realDoor = makeEntity(id: "binary_sensor.example_e1938001", state: "on", attrs: [
            "friendly_name": .string("Front Door")
        ])
        HAClient.shared.entities = [realDoor.entityId: realDoor]
        vm = HomeViewModel(explicitDemoMode: false, fetchStates: {
            throw HAClientError.unavailable
        })
        vm.isConfigured = true

        await vm.refresh()

        XCTAssertEqual(vm.presentationState, .lastKnown)
        XCTAssertFalse(vm.isDemoMode)
        XCTAssertEqual(HAClient.shared.entity(realDoor.entityId), realDoor)
        XCTAssertNil(HAClient.shared.entity("light.example_d7ab5b9b"))
        XCTAssertFalse(vm.canPerformActions)
    }

    func testConfiguredFailureWithoutRealStateShowsUnavailable() async {
        HAClient.shared.reset()
        HAClient.shared.setBackendConfigured(true)
        vm = HomeViewModel(explicitDemoMode: false, fetchStates: {
            throw HAClientError.unavailable
        })
        vm.isConfigured = true

        await vm.refresh()

        XCTAssertEqual(vm.presentationState, .unavailable)
        XCTAssertFalse(vm.isDemoMode)
        XCTAssertTrue(HAClient.shared.entities.isEmpty)
        XCTAssertFalse(vm.canPerformActions)
    }

    func testUnconfiguredRefreshShowsSetupStateWithoutDemo() async {
        HAClient.shared.reset()
        vm = HomeViewModel(explicitDemoMode: false)
        vm.isConfigured = false

        await vm.refresh()

        XCTAssertEqual(vm.presentationState, .notConfigured)
        XCTAssertFalse(vm.isDemoMode)
        XCTAssertTrue(HAClient.shared.entities.isEmpty)
    }

    func testMockDataPopulatesHeatingRooms() async {
        await vm.refresh()
        XCTAssertFalse(vm.heatingRooms.isEmpty)
    }

    func testMockDataPopulatesLights() async {
        await vm.refresh()
        XCTAssertFalse(vm.lightsOn.isEmpty)
    }

    func testMockDataPopulatesTotalLights() async {
        await vm.refresh()
        XCTAssertGreaterThan(vm.totalLights, 0)
    }

    func testMockDataPopulatesDoors() async {
        await vm.refresh()
        XCTAssertFalse(vm.doorStatuses.isEmpty)
    }

    func testMockDataPopulatesScenes() async {
        await vm.refresh()
        XCTAssertFalse(vm.scenes.isEmpty)
    }

    func testMockDataSetsIsMockDataTrue() async {
        await vm.refresh()
        XCTAssertTrue(vm.isMockData)
    }

    func testMockDataClearsErrorMessage() async {
        vm.errorMessage = "Previous error"
        await vm.refresh()
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Derived State: heatingRooms (via mock data)

    func testHeatingRoomsHaveNames() async {
        await vm.refresh()
        for room in vm.heatingRooms {
            XCTAssertFalse(room.name.isEmpty, "Heating room should have a name")
        }
    }

    func testHeatingRoomsHaveTemperatures() async {
        await vm.refresh()
        for room in vm.heatingRooms {
            XCTAssertNotNil(room.currentTemp, "Heating room \(room.name) should have current temp")
            XCTAssertNotNil(room.targetTemp, "Heating room \(room.name) should have target temp")
        }
    }

    func testHeatingRoomIdMatchesEntityId() async {
        await vm.refresh()
        for room in vm.heatingRooms {
            XCTAssertTrue(room.id.hasPrefix("climate."), "Heating room ID should start with climate.")
        }
    }

    // MARK: - Derived State: lightsOn / totalLights (via mock data)

    func testLightsOnAllHaveNames() async {
        await vm.refresh()
        for light in vm.lightsOn {
            XCTAssertFalse(light.name.isEmpty, "Light should have a name")
        }
    }

    func testLightsOnCountMatchesTotalOrLess() async {
        await vm.refresh()
        let onCount = vm.lightsOn.filter(\.isOn).count
        XCTAssertLessThanOrEqual(onCount, vm.totalLights)
    }

    func testTotalLightsEqualsLightsOnArrayCount() async {
        await vm.refresh()
        // lightsOn contains ALL lights (both on and off), totalLights is the count
        XCTAssertEqual(vm.totalLights, vm.lightsOn.count)
    }

    // MARK: - Derived State: doorStatuses (via mock data)

    func testDoorStatusesHaveNames() async {
        await vm.refresh()
        for door in vm.doorStatuses {
            XCTAssertFalse(door.name.isEmpty, "Door should have a name")
        }
    }

    func testDoorStatusesHaveBinarySensorIds() async {
        await vm.refresh()
        for door in vm.doorStatuses {
            XCTAssertTrue(door.id.hasPrefix("binary_sensor."), "Door ID should start with binary_sensor.")
        }
    }

    // MARK: - Derived State: scenes (via mock data)

    func testScenesHaveDisplayNames() async {
        await vm.refresh()
        for scene in vm.scenes {
            XCTAssertFalse(scene.displayName.isEmpty, "Scene should have a display name")
        }
    }

    func testScenesHaveValidDomains() async {
        await vm.refresh()
        for scene in vm.scenes {
            XCTAssertTrue(scene.domain == "scene" || scene.domain == "script",
                          "Scene domain should be 'scene' or 'script', got '\(scene.domain)'")
        }
    }

    func testSceneIconForSceneDomain() async {
        await vm.refresh()
        for scene in vm.scenes where scene.domain == "scene" {
            XCTAssertEqual(scene.icon, "play.circle")
        }
    }

    func testSceneIconForScriptDomain() async {
        await vm.refresh()
        for scene in vm.scenes where scene.domain == "script" {
            XCTAssertEqual(scene.icon, "bolt.circle")
        }
    }

    // MARK: - Actions: Toggle Light

    func testToggleLightOptimisticUpdate() async {
        HAClient.shared.entities["light.example_d7ab5b9b"] = makeEntity(id: "light.example_d7ab5b9b", state: "on")
        await vm.toggleLight("light.example_d7ab5b9b")
        XCTAssertEqual(HAClient.shared.entity("light.example_d7ab5b9b")?.state, "off")
    }

    func testToggleLightOffToOn() async {
        HAClient.shared.entities["light.example_d7ab5b9b"] = makeEntity(id: "light.example_d7ab5b9b", state: "off")
        await vm.toggleLight("light.example_d7ab5b9b")
        XCTAssertEqual(HAClient.shared.entity("light.example_d7ab5b9b")?.state, "on")
    }

    // MARK: - Actions: Toggle Device

    func testToggleDeviceOptimisticUpdate() async {
        HAClient.shared.entities["switch.plug1"] = makeEntity(id: "switch.plug1", state: "off")
        await vm.toggleDevice("switch.plug1")
        XCTAssertEqual(HAClient.shared.entity("switch.plug1")?.state, "on")
    }

    func testToggleDeviceOnToOff() async {
        HAClient.shared.entities["switch.plug1"] = makeEntity(id: "switch.plug1", state: "on")
        await vm.toggleDevice("switch.plug1")
        XCTAssertEqual(HAClient.shared.entity("switch.plug1")?.state, "off")
    }

    // MARK: - Actions: Temperature

    func testSetTemperatureOptimisticUpdate() async {
        HAClient.shared.entities["climate.example_dfadd42f"] = makeEntity(id: "climate.example_dfadd42f", state: "heat", attrs: [
            "temperature": .double(20.0),
        ])
        await vm.setTemperature("climate.example_dfadd42f", temperature: 22.0)
        let target = HAClient.shared.entity("climate.example_dfadd42f")?.targetTemperature
        XCTAssertEqual(target, 22.0)
    }

    // MARK: - Actions: HVAC Mode

    func testSetHVACModeOptimisticUpdate() async {
        HAClient.shared.entities["climate.example_5b2bd3d4"] = makeEntity(id: "climate.example_5b2bd3d4", state: "heat")
        await vm.setHVACMode("climate.example_5b2bd3d4", mode: "off")
        XCTAssertEqual(HAClient.shared.entity("climate.example_5b2bd3d4")?.state, "off")
    }

    // MARK: - Actions: Media Player

    func testMediaPlayPauseOptimisticUpdatePlaying() async {
        HAClient.shared.entities["media_player.example_0602377b"] = makeEntity(
            id: "media_player.example_0602377b", state: "playing"
        )
        await vm.mediaPlayPause("media_player.example_0602377b")
        XCTAssertEqual(HAClient.shared.entity("media_player.example_0602377b")?.state, "paused")
    }

    func testMediaPlayPauseOptimisticUpdatePaused() async {
        HAClient.shared.entities["media_player.example_0602377b"] = makeEntity(
            id: "media_player.example_0602377b", state: "paused"
        )
        await vm.mediaPlayPause("media_player.example_0602377b")
        XCTAssertEqual(HAClient.shared.entity("media_player.example_0602377b")?.state, "playing")
    }

    func testMediaNextOptimisticUpdate() async {
        HAClient.shared.entities["media_player.example_0602377b"] = makeEntity(
            id: "media_player.example_0602377b", state: "playing", attrs: [
                "media_title": .string("Old Song"),
                "media_position": .double(120),
            ]
        )
        await vm.mediaNext("media_player.example_0602377b")
        XCTAssertEqual(HAClient.shared.entity("media_player.example_0602377b")?.mediaTitle, "...")
    }

    func testSetVolumeOptimisticUpdate() async {
        HAClient.shared.entities["media_player.example_0602377b"] = makeEntity(
            id: "media_player.example_0602377b", state: "playing", attrs: [
                "volume_level": .double(0.3),
            ]
        )
        await vm.setVolume("media_player.example_0602377b", level: 0.8)
        XCTAssertEqual(HAClient.shared.entity("media_player.example_0602377b")?.volumeLevel, 0.8)
    }

    func testToggleMuteOptimisticUpdate() async {
        HAClient.shared.entities["media_player.example_0602377b"] = makeEntity(
            id: "media_player.example_0602377b", state: "playing", attrs: [
                "is_volume_muted": .bool(false),
            ]
        )
        await vm.toggleMute("media_player.example_0602377b")
        XCTAssertEqual(HAClient.shared.entity("media_player.example_0602377b")?.isVolumeMuted, true)
    }

    func testSetShuffleOptimisticUpdate() async {
        HAClient.shared.entities["media_player.example_0602377b"] = makeEntity(
            id: "media_player.example_0602377b", state: "playing", attrs: [
                "shuffle": .bool(false),
            ]
        )
        await vm.setShuffle("media_player.example_0602377b", enabled: true)
        XCTAssertEqual(HAClient.shared.entity("media_player.example_0602377b")?.shuffleEnabled, true)
    }

    func testSetRepeatOptimisticUpdate() async {
        HAClient.shared.entities["media_player.example_0602377b"] = makeEntity(
            id: "media_player.example_0602377b", state: "playing", attrs: [
                "repeat": .string("off"),
            ]
        )
        await vm.setRepeat("media_player.example_0602377b", mode: "all")
        XCTAssertEqual(HAClient.shared.entity("media_player.example_0602377b")?.repeatMode, "all")
    }

    // MARK: - Scenes: Activate

    func testActivateSceneSetsToast() async {
        await vm.refresh() // Load mock data so scenes are populated
        if let scene = vm.scenes.first {
            await vm.activateScene(scene.entityId)
            XCTAssertNotNil(vm.toastMessage)
        }
    }

    func testActivateSceneToastContainsName() async {
        await vm.refresh()
        if let scene = vm.scenes.first {
            await vm.activateScene(scene.entityId)
            XCTAssertTrue(vm.toastMessage?.contains("Activated") ?? false)
        }
    }

    func testActivateSceneToastIsNotWarning() async {
        await vm.refresh()
        if let scene = vm.scenes.first {
            await vm.activateScene(scene.entityId)
            XCTAssertFalse(vm.toastIsWarning)
        }
    }

    // MARK: - Scenes: Favorites

    func testToggleSceneFavorite() async {
        await vm.refresh()
        guard let scene = vm.scenes.first else {
            XCTFail("No scenes in mock data")
            return
        }
        let beforeFavorite = scene.isFavorite
        vm.toggleSceneFavorite(scene.entityId)
        let afterFavorite = vm.scenes.first(where: { $0.entityId == scene.entityId })?.isFavorite
        XCTAssertNotEqual(beforeFavorite, afterFavorite)
    }

    func testToggleSceneFavoritePersists() async {
        await vm.refresh()
        guard let scene = vm.scenes.first else { return }
        vm.toggleSceneFavorite(scene.entityId)
        let favorites = UserDefaults.standard.stringArray(forKey: "favorite_scenes") ?? []
        XCTAssertTrue(favorites.contains(scene.entityId))
    }

    func testToggleSceneFavoriteDoubleToggleRemoves() async {
        await vm.refresh()
        guard let scene = vm.scenes.first else { return }
        vm.toggleSceneFavorite(scene.entityId)
        vm.toggleSceneFavorite(scene.entityId)
        let favorites = UserDefaults.standard.stringArray(forKey: "favorite_scenes") ?? []
        XCTAssertFalse(favorites.contains(scene.entityId))
    }

    func testScenesSortFavoritesFirst() async {
        await vm.refresh()
        guard vm.scenes.count >= 2 else { return }
        let lastScene = vm.scenes.last!
        vm.toggleSceneFavorite(lastScene.entityId)
        XCTAssertEqual(vm.scenes.first?.entityId, lastScene.entityId)
    }

    // MARK: - Status Banner Computed Properties

    func testStatusTemperatureWithMockData() async {
        await vm.refresh()
        // Mock data includes climate entities, so statusTemperature should be non-nil
        XCTAssertNotNil(vm.statusTemperature)
    }

    func testStatusTemperatureFormat() async {
        await vm.refresh()
        guard let temp = vm.statusTemperature else {
            XCTFail("Expected statusTemperature to be non-nil with mock data")
            return
        }
        // Should end with degree C
        XCTAssertTrue(temp.hasSuffix("\u{00B0}C"), "Temperature should end with degree symbol + C")
    }

    func testStatusTemperatureNilWhenNoRooms() async {
        HAClient.shared.entities = [:]
        await vm.refresh()
        XCTAssertTrue(vm.heatingRooms.isEmpty)
        XCTAssertNil(vm.statusTemperature)
    }

    func testStatusDoorSummaryAllClosedWithMockData() async {
        await vm.refresh()
        // Check it returns a non-empty string
        XCTAssertFalse(vm.statusDoorSummary.isEmpty)
    }

    func testStatusDoorSummaryAllClosedFormat() async {
        await vm.refresh()
        // With mock data, doors should be closed
        let summary = vm.statusDoorSummary
        // Either "ALL CLOSED" or contains "OPEN"
        XCTAssertTrue(summary == "ALL CLOSED" || summary.contains("OPEN"))
    }

    func testStatusSonosSummaryWithMockData() async {
        await vm.refresh()
        // Mock data may or may not have a playing Sonos
        // Just verify it doesn't crash and returns a valid type
        let _ = vm.statusSonosSummary
    }

    // MARK: - Error Handling

    func testLastKnownStateDoesNotOptimisticallyMutateWhenActionCannotBeSent() async {
        HAClient.shared.reset()
        HAClient.shared.setBackendConfigured(true)
        let light = makeEntity(id: "light.test", state: "on")
        HAClient.shared.entities[light.entityId] = light
        vm = HomeViewModel(explicitDemoMode: false, fetchStates: {
            throw HAClientError.unavailable
        })
        vm.isConfigured = true
        await vm.refresh()

        await vm.toggleLight("light.test")

        XCTAssertEqual(HAClient.shared.entity("light.test")?.state, "on")
        XCTAssertNil(vm.errorMessage)
    }

    func testRefreshWithoutConfigDoesNothing() async {
        HAClient.shared.reset()
        vm = HomeViewModel(explicitDemoMode: false)
        vm.isConfigured = false
        await vm.refresh()
        XCTAssertTrue(vm.heatingRooms.isEmpty)
        XCTAssertTrue(vm.lightsOn.isEmpty)
        XCTAssertEqual(vm.presentationState, .notConfigured)
    }

    // MARK: - Anomaly Detection (smoke tests)

    func testAnomalyCheckDoesNotCrashWhenActive() async {
        vm.scenePhase = .active
        await vm.refresh()
        // checkForAnomalies is called inside computeDerivedState
        // Just verify no crash
    }

    func testAnomalyCheckDoesNotCrashWhenBackground() async {
        vm.scenePhase = .background
        await vm.refresh()
        // Just verify no crash
    }

    // MARK: - Door Camera Map

    func testDoorCameraMapContainsFrontDoor() {
        XCTAssertNotNil(HomeViewModel.doorCameraMap["binary_sensor.example_e1938001"])
    }

    func testDoorCameraMapContainsBackDoor() {
        XCTAssertNotNil(HomeViewModel.doorCameraMap["binary_sensor.example_cadfe0f1"])
    }

    func testDoorCameraMapValuesAreSelectEntities() {
        for (_, value) in HomeViewModel.doorCameraMap {
            XCTAssertTrue(value.hasPrefix("select."), "Camera map values should be select entities")
        }
    }
}

private final class ProtectionRecordingFileManager: FileManager {
    private let recordLock = NSLock()
    private var protectionsByPath: [String: String] = [:]

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        guard let protection = attributes[.protectionKey] as? FileProtectionType else {
            return
        }
        recordLock.withLock {
            protectionsByPath[path] = protection.rawValue
        }
    }

    func protection(atPath path: String) -> String? {
        recordLock.withLock { protectionsByPath[path] }
    }
}
