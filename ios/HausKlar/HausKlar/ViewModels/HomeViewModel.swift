import AVKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import os

struct HomeOfflineSnapshot: Codable, Equatable {
    let entities: [String: HAEntity]
    let fetchedAt: Date
    let manifest: HomeManifestDTO?
    let sitrep: HomeSitrepDTO?
}

enum HomeSnapshotStoreError: Error, Equatable {
    case invalidFile
    case snapshotTooLarge
}

/// Identity-scoped, complete-file-protected storage for the last real Home
/// snapshot. A one-way hash keeps family/user identifiers out of filenames.
actor HomeSnapshotStore {
    static let shared = HomeSnapshotStore()
    static let maximumSnapshotBytes = 5 * 1024 * 1024

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "HomeSnapshotStore"
    )

    struct IdentityLease: Equatable, Sendable {
        let identity: String
        let generation: UInt64
    }

    private let directory: URL
    private let fileManager: FileManager
    private var activeIdentity: String?
    private var generation: UInt64 = 0

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory
            ?? support.appendingPathComponent("HomeSnapshots", isDirectory: true)
    }

    func activate(identity: String) {
        generation &+= 1
        activeIdentity = identity
    }

    func suspend() {
        generation &+= 1
        activeIdentity = nil
    }

    func lease(identity: String) -> IdentityLease? {
        guard activeIdentity == identity else { return nil }
        return IdentityLease(identity: identity, generation: generation)
    }

    func save(_ snapshot: HomeOfflineSnapshot, lease: IdentityLease) throws {
        guard activeIdentity == lease.identity,
              generation == lease.generation else { throw APIError.unauthorized }
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumSnapshotBytes else {
            throw HomeSnapshotStoreError.snapshotTooLarge
        }
        let file = fileURL(identity: lease.identity)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try LocalFileProtection.protectItem(at: file, fileManager: fileManager)
        guard activeIdentity == lease.identity,
              generation == lease.generation else {
            do {
                try fileManager.removeItem(at: file)
            } catch {
                Self.logger.error(
                    "Stale Home snapshot cleanup failed. Reconciliation: the next identity purge retries removal of the scoped snapshot directory."
                )
            }
            throw APIError.unauthorized
        }
    }

    func load(identity: String) throws -> HomeOfflineSnapshot? {
        guard activeIdentity == identity else { return nil }
        let file = fileURL(identity: identity)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let values = try file.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= Self.maximumSnapshotBytes else {
            throw HomeSnapshotStoreError.invalidFile
        }
        return try JSONDecoder().decode(
            HomeOfflineSnapshot.self,
            from: Data(contentsOf: file, options: .mappedIfSafe)
        )
    }

    func remove(identity: String) throws {
        guard activeIdentity == identity else { return }
        let file = fileURL(identity: identity)
        if fileManager.fileExists(atPath: file.path) {
            try fileManager.removeItem(at: file)
        }
    }

    func securePurge() throws {
        suspend()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
    }

    func fileURL(identity: String) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return directory.appendingPathComponent(filename, isDirectory: false)
    }
}

enum FloorPlanViewMode: String, CaseIterable {
    case threeD = "3D"
    case twoD = "2D"
}

enum HomePresentationState: Equatable {
    case loading
    case notConfigured
    case live
    case lastKnown
    case unavailable
    case demo
}

/// Response from GET /api/family/settings/ha on the HausKlar backend.
struct HASettingsResponse: Codable {
    let dashboardUrl: String?
    let haUrl: String?
    let configApiUrl: String?
    let tokenConfigured: Bool
    let configured: Bool
}

/// View model for the Home tab. Derives display state from HAClient entities.
/// Media player, Spotify browse, camera, and anomaly logic are delegated to sub-VMs/services.
@MainActor
final class HomeViewModel: ObservableObject {

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "HomeViewModel"
    )

    // MARK: - Published State

    @Published var isLoading: Bool = false
    @Published var isConfigured: Bool = false
    @Published private(set) var isDemoMode: Bool = false
    @Published private(set) var presentationState: HomePresentationState = .loading
    @Published var errorMessage: String?
    @Published var selectedFloor: Int = 0
    @Published var viewMode: FloorPlanViewMode = .threeD
    @Published var selectedDevice: FloorPlanDevice?
    @Published var floorPlanDevices: [FloorPlanDevice] = []
    @Published var floorPlanRooms: [FloorPlanRoom] = []
    @Published private(set) var manifest: HomeManifestDTO?
    @Published private(set) var sitrep: HomeSitrepDTO?

    // Toast feedback (forwarded from mediaPlayerVM)
    @Published var toastMessage: String?
    @Published var toastIsWarning: Bool = false

    // Schedule-aware automation suggestions
    @Published var suggestedAutomations: [SuggestedAutomation] = []

    // Derived display properties
    @Published var heatingRooms: [HeatingRoom] = []
    @Published var lightsOn: [LightInfo] = []
    @Published var totalLights: Int = 0
    @Published var doorStatuses: [DoorStatus] = []
    @Published var doorCameraAvailable: [String: Bool] = [:]
    @Published var sonosPlayers: [SonosPlayer] = []
    @Published var appliances: [ApplianceStatus] = []
    @Published var scenes: [SceneInfo] = []

    // State caching (#26)
    @Published var cachedStateTimestamp: Date?

    let haClient = HAClient.shared
    private var cancellables = Set<AnyCancellable>()
    private let automationService = ScheduleAutomationService.shared
    private let explicitDemoMode: Bool
    private let fetchStates: @MainActor () async throws -> Void
    private let snapshotStore: HomeSnapshotStore
    private let cacheIdentity: () -> String?

    /// Backward-compatible name used by existing floor-plan components.
    var isMockData: Bool { isDemoMode }

    /// Only live and unmistakably labelled demo state may mutate displayed entities.
    var canPerformActions: Bool {
        presentationState == .live || presentationState == .demo
    }

    // MARK: - Sub-ViewModels and Services

    let mediaPlayerVM: MediaPlayerViewModel
    let spotifyBrowseVM: SpotifyBrowseViewModel
    let cameraVM: CameraViewModel
    let anomalyService: AnomalyService

    /// Current scene phase -- set from the SwiftUI environment to gate background notifications.
    var scenePhase: ScenePhase = .active

    init(
        explicitDemoMode: Bool = ProcessInfo.processInfo.arguments.contains("--hausklar-home-demo"),
        fetchStates: (@MainActor () async throws -> Void)? = nil,
        snapshotStore: HomeSnapshotStore = .shared,
        cacheIdentity: @escaping () -> String? = { APIClient.shared.cacheIdentity }
    ) {
        let client = HAClient.shared
        self.explicitDemoMode = explicitDemoMode
        self.fetchStates = fetchStates ?? { try await client.fetchAllStates() }
        self.snapshotStore = snapshotStore
        self.cacheIdentity = cacheIdentity
        mediaPlayerVM = MediaPlayerViewModel(haClient: client)
        spotifyBrowseVM = SpotifyBrowseViewModel(haClient: client)
        cameraVM = CameraViewModel(haClient: client)
        anomalyService = AnomalyService()
        manifest = client.manifest
        sitrep = client.sitrep

        bindClient()
        if explicitDemoMode {
            activateExplicitDemo()
        } else if client.isDemoMode {
            client.discardDisplayedState()
        }
    }

    private func bindClient() {
        haClient.$entities
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.computeDerivedState() }
            .store(in: &cancellables)

        haClient.$isConnected
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self, !self.isDemoMode, self.isConfigured else { return }
                if connected {
                    self.presentationState = .live
                    Task { @MainActor [weak self] in
                        await self?.cacheCurrentState()
                    }
                } else {
                    self.presentationState = self.haClient.entities.isEmpty ? .unavailable : .lastKnown
                }
            }
            .store(in: &cancellables)

        haClient.$manifest
            .receive(on: RunLoop.main)
            .sink { [weak self] manifest in self?.manifest = manifest }
            .store(in: &cancellables)

        haClient.$sitrep
            .receive(on: RunLoop.main)
            .sink { [weak self] sitrep in self?.sitrep = sitrep }
            .store(in: &cancellables)

        mediaPlayerVM.$toastMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in self?.toastMessage = message }
            .store(in: &cancellables)

        mediaPlayerVM.$toastIsWarning
            .receive(on: RunLoop.main)
            .sink { [weak self] warning in self?.toastIsWarning = warning }
            .store(in: &cancellables)
    }

    private func activateExplicitDemo() {
        haClient.loadDemoData()
        isConfigured = false
        isDemoMode = true
        presentationState = .demo
        errorMessage = nil
        computeDerivedState()
    }

    // MARK: - Data Structures

    struct HeatingRoom: Identifiable {
        let id: String
        let name: String
        let currentTemp: Double?
        let targetTemp: Double?
        let isHeating: Bool
    }

    struct LightInfo: Identifiable {
        let id: String
        let name: String
        let isOn: Bool
        let brightness: Int?
    }

    struct DoorStatus: Identifiable {
        let id: String
        let name: String
        let isOpen: Bool
        var lastOpenedAt: Date?
        var openDuration: TimeInterval?
        var isStillOpen: Bool = false
    }

    struct SonosPlayer: Identifiable {
        let id: String
        let name: String
        let state: String
        let mediaTitle: String?
        let mediaArtist: String?
    }

    struct ApplianceStatus: Identifiable {
        let id: String
        let name: String
        let status: String
    }

    struct SceneInfo: Identifiable {
        let id: String
        let entityId: String
        let displayName: String
        let icon: String
        let domain: String // "scene" or "script"
        var isFavorite: Bool
    }

    // MARK: - Backward-Compatible Type Aliases
    // These allow existing views (DeviceActionSheet, DoorVideoSheet) to reference
    // HomeViewModel.BrowseItem / HomeViewModel.BrowseResult without changes.

    typealias BrowseItem = SpotifyBrowseViewModel.BrowseItem
    typealias BrowseResult = SpotifyBrowseViewModel.BrowseResult

    // MARK: - Settings Loading

    /// Load only the backend's configuration status. HA credentials never enter iOS.
    func loadSettings() async {
        guard !explicitDemoMode else {
            activateExplicitDemo()
            return
        }

        isLoading = true
        defer { isLoading = false }
        KeychainManager.deleteLegacyHomeAssistantCredentials()

        do {
            let settings: HASettingsResponse = try await APIClient.shared.get("/family/settings/ha")
            isConfigured = settings.configured
            haClient.setBackendConfigured(settings.configured)
            isDemoMode = false

            if settings.configured {
                if haClient.isConnected {
                    presentationState = .live
                } else if !haClient.entities.isEmpty {
                    presentationState = .lastKnown
                    computeDerivedState()
                }
            } else {
                haClient.discardDisplayedState()
                await clearCachedState()
                presentationState = .notConfigured
                computeDerivedState()
            }
        } catch {
            isConfigured = haClient.isConfigured
            isDemoMode = false
            if !haClient.entities.isEmpty {
                presentationState = .lastKnown
                computeDerivedState()
            } else {
                presentationState = .unavailable
            }
        }
    }

    // MARK: - State Caching (#26)

    private static let cachedStatesKey = HomeSnapshotCacheKeys.states
    private static let cachedTimestampKey = HomeSnapshotCacheKeys.timestamp
    private static let cachedManifestKey = HomeSnapshotCacheKeys.manifest
    private static let cachedSitrepKey = HomeSnapshotCacheKeys.sitrep

    /// Cache the last successful real snapshot for quiet offline display.
    func cacheCurrentState() async {
        guard isConfigured, !isDemoMode, haClient.isConnected, !haClient.entities.isEmpty,
              let identity = cacheIdentity(),
              let lease = await snapshotStore.lease(identity: identity) else { return }
        let timestamp = haClient.lastFetch ?? Date()
        do {
            try await snapshotStore.save(
                HomeOfflineSnapshot(
                    entities: haClient.entities,
                    fetchedAt: timestamp,
                    manifest: manifest,
                    sitrep: sitrep
                ),
                lease: lease
            )
            clearLegacySnapshotDefaults()
            cachedStateTimestamp = timestamp
        } catch {
            // Last-known Home state is best-effort; never replace a durable file
            // with a less protected fallback if protected persistence fails.
            Self.logger.error(
                "Home snapshot publication failed; the previous protected snapshot remains authoritative."
            )
        }
    }

    /// Restore only a full real snapshot; legacy state-only caches are intentionally ignored.
    func loadCachedState() async {
        guard !explicitDemoMode,
              haClient.entities.isEmpty,
              let identity = cacheIdentity(),
              let snapshot = await loadProtectedOrMigrateLegacySnapshot(identity: identity),
              !snapshot.entities.isEmpty else { return }
        cachedStateTimestamp = snapshot.fetchedAt
        haClient.restoreLastKnownEntities(
            snapshot.entities,
            fetchedAt: snapshot.fetchedAt,
            manifest: snapshot.manifest,
            sitrep: snapshot.sitrep
        )
        isConfigured = true
        haClient.setBackendConfigured(true)
        presentationState = .lastKnown
        computeDerivedState()
    }

    private func clearCachedState() async {
        if let identity = cacheIdentity() {
            do {
                try await snapshotStore.remove(identity: identity)
            } catch {
                Self.logger.error(
                    "Home snapshot removal failed. Reconciliation: the next cache clear or identity purge retries removal."
                )
            }
        }
        clearLegacySnapshotDefaults()
        cachedStateTimestamp = nil
    }

    /// Load cached state timestamp for "Last updated X ago" display.
    func loadCachedTimestamp() async {
        guard let identity = cacheIdentity(),
              let snapshot = await loadProtectedOrMigrateLegacySnapshot(identity: identity) else { return }
        cachedStateTimestamp = snapshot.fetchedAt
    }

    private func loadProtectedOrMigrateLegacySnapshot(
        identity: String
    ) async -> HomeOfflineSnapshot? {
        do {
            if let snapshot = try await snapshotStore.load(identity: identity) {
                return snapshot
            }
        } catch {
            Self.logger.error(
                "Protected Home snapshot could not be read; attempting the owner-verified legacy migration path."
            )
        }

        // Migrate the global legacy cache only when the separately persisted
        // local-store owner proves it belongs to this exact identity.
        let defaults = UserDefaults.standard
        // The remaining decodes are deliberate legacy-schema probes. Invalid
        // required entities discard the legacy cache; malformed additive fields
        // are omitted while the verified entity snapshot remains usable.
        guard defaults.string(forKey: AppState.localOwnerKey) == identity,
              let data = defaults.data(forKey: Self.cachedStatesKey),
              let entities = try? JSONDecoder().decode([String: HAEntity].self, from: data),
              !entities.isEmpty else {
            clearLegacySnapshotDefaults()
            return nil
        }
        let manifest = defaults.data(forKey: Self.cachedManifestKey)
            .flatMap { try? JSONDecoder().decode(HomeManifestDTO.self, from: $0) }
        let sitrep = defaults.data(forKey: Self.cachedSitrepKey)
            .flatMap { try? JSONDecoder().decode(HomeSitrepDTO.self, from: $0) }
        let timestampValue = defaults.double(forKey: Self.cachedTimestampKey)
        let snapshot = HomeOfflineSnapshot(
            entities: entities,
            fetchedAt: timestampValue > 0 ? Date(timeIntervalSince1970: timestampValue) : Date(),
            manifest: manifest,
            sitrep: sitrep
        )
        do {
            guard let lease = await snapshotStore.lease(identity: identity) else { return nil }
            try await snapshotStore.save(snapshot, lease: lease)
            clearLegacySnapshotDefaults()
            return snapshot
        } catch {
            Self.logger.error(
                "Legacy Home snapshot migration failed; no unprotected fallback was published."
            )
            return nil
        }
    }

    private func clearLegacySnapshotDefaults() {
        for key in HomeSnapshotCacheKeys.all {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Background Polling Control (#29)

    /// Pause HA polling when app enters background.
    func pausePolling() {
        haClient.pausePolling()
    }

    /// Resume HA polling when app returns to foreground.
    func resumePolling() {
        haClient.resumePolling()
    }

    // MARK: - Refresh

    /// Fetch HA states and compute derived display properties without substituting samples.
    func refresh() async {
        if isDemoMode {
            presentationState = .demo
            computeDerivedState()
            errorMessage = nil
            return
        }
        guard isConfigured else {
            presentationState = .notConfigured
            return
        }

        do {
            try await fetchStates()
            isConfigured = haClient.isConfigured
            isDemoMode = false
            presentationState = .live
            computeDerivedState()
            await cacheCurrentState()
            errorMessage = nil
        } catch {
            isConfigured = haClient.isConfigured
            isDemoMode = false
            computeDerivedState()
            if !isConfigured {
                presentationState = .notConfigured
            } else {
                presentationState = haClient.entities.isEmpty ? .unavailable : .lastKnown
            }
            errorMessage = nil
        }
    }

    func retry() async {
        if !isConfigured {
            await loadSettings()
        }
        if isConfigured {
            await refresh()
            haClient.startPolling()
        }
    }

    /// Start polling and do an initial refresh.
    func startMonitoring() async {
        if explicitDemoMode {
            activateExplicitDemo()
            await loadFloorPlanConfig()
            return
        }

        await loadCachedState()
        await loadSettings()
        await loadFloorPlanConfig()

        guard isConfigured else { return }
        await refresh()
        haClient.startPolling()
    }

    // MARK: - Floor Plan Config

    /// Load device positions and room configs from the dashboard config API.
    /// Falls back to hardcoded defaults if the API is unreachable.
    private func loadFloorPlanConfig() async {
        let config: FloorPlanConfig
        do {
            config = try await ConfigAPIClient.shared.fetchConfig()
        } catch {
            config = ConfigAPIClient.shared.fallbackConfig()
        }
        if isDemoMode {
            // Swap family names for generic labels in demo mode
            floorPlanDevices = config.devices.map { device in
                let newLabel = FloorPlanData.demoLabel(device.label, isDemoMode: true)
                guard newLabel != device.label else { return device }
                return FloorPlanDevice(id: device.id, entityId: device.entityId, type: device.type, floor: device.floor, x: device.x, y: device.y, room: device.room, label: newLabel)
            }
        } else {
            floorPlanDevices = config.devices
        }
        floorPlanRooms = config.rooms
    }

    /// Stop polling.
    func stopMonitoring() {
        haClient.stopPolling()
    }

    // MARK: - Actions

    /// Perform an HA service call with optional optimistic UI update.
    /// Applies the optimistic update immediately, fires the service call,
    /// then schedules a background refresh to confirm the real state.
    func performAction(
        domain: String, service: String, data: [String: Any],
        optimisticUpdate: (() -> Void)? = nil
    ) async {
        guard canPerformActions else { return }
        optimisticUpdate?()
        // Recompute derived state immediately so UI reflects optimistic update
        computeDerivedState()
        // In demo mode, just apply the optimistic update — no real HA to call
        guard !isDemoMode else { return }
        do {
            try await haClient.callService(domain: domain, service: service, data: data)
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
        haClient.scheduleBackgroundRefresh()
    }

    func saveFavourites(_ entityIds: [String]) async -> Bool {
        guard presentationState == .live else {
            errorMessage = "Connect to the live house before changing shared favourites."
            return false
        }
        do {
            _ = try await haClient.saveHomeFavourites(entityIds)
            toastMessage = "House favourites saved"
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Favourites could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func performBroadAction(_ choice: HomeBroadActionChoice) async -> Bool {
        guard presentationState == .live else {
            errorMessage = "Connect to the live house before running a broad action."
            return false
        }
        do {
            let entityIds = try await haClient.performBroadAction(choice)
            toastMessage = "\(entityIds.count) light\(entityIds.count == 1 ? "" : "s") updated"
            errorMessage = nil
            return true
        } catch {
            errorMessage = "The house action failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Toggle a light entity.
    func toggleLight(_ entityId: String) async {
        let currentState = haClient.entity(entityId)?.state
        let newState = currentState == "on" ? "off" : "on"
        await performAction(domain: "light", service: "toggle", data: ["entity_id": entityId]) { [self] in
            haClient.updateEntityOptimistically(entityId, state: newState)
        }
    }

    /// Set brightness for a light entity (0-255).
    func setBrightness(_ entityId: String, brightness: Int) async {
        await performAction(domain: "light", service: "turn_on", data: [
            "entity_id": entityId,
            "brightness": brightness,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "brightness": .int(brightness)
            ])
        }
    }

    /// Toggle a device (light or switch) by entity ID.
    func toggleDevice(_ entityId: String) async {
        let domain = String(entityId.prefix(while: { $0 != "." }))
        let currentState = haClient.entity(entityId)?.state
        let newState = currentState == "on" ? "off" : "on"
        await performAction(domain: domain, service: "toggle", data: ["entity_id": entityId]) { [self] in
            haClient.updateEntityOptimistically(entityId, state: newState)
        }
    }

    /// Set target temperature for a climate entity.
    func setTemperature(_ entityId: String, temperature: Double) async {
        await performAction(domain: "climate", service: "set_temperature", data: [
            "entity_id": entityId,
            "temperature": temperature,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "temperature": .double(temperature)
            ])
        }
    }

    /// Set HVAC mode for a climate entity (e.g. "off", "heat", "auto").
    func setHVACMode(_ entityId: String, mode: String) async {
        await performAction(domain: "climate", service: "set_hvac_mode", data: [
            "entity_id": entityId,
            "hvac_mode": mode,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, state: mode)
        }
    }

    // MARK: - Media Player Delegation

    /// Toggle play/pause on a media player. Delegates to MediaPlayerViewModel.
    func mediaPlayPause(_ entityId: String) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.mediaPlayPause(entityId)
    }

    /// Skip to next track. Delegates to MediaPlayerViewModel.
    func mediaNext(_ entityId: String) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.mediaNext(entityId)
    }

    /// Skip to previous track. Delegates to MediaPlayerViewModel.
    func mediaPrevious(_ entityId: String) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.mediaPrevious(entityId)
    }

    /// Set volume level. Delegates to MediaPlayerViewModel.
    func setVolume(_ entityId: String, level: Double) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.setVolume(entityId, level: level)
    }

    /// Toggle mute. Delegates to MediaPlayerViewModel.
    func toggleMute(_ entityId: String) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.toggleMute(entityId)
    }

    /// Set shuffle mode. Delegates to MediaPlayerViewModel.
    func setShuffle(_ entityId: String, enabled: Bool) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.setShuffle(entityId, enabled: enabled)
    }

    /// Set repeat mode. Delegates to MediaPlayerViewModel.
    func setRepeat(_ entityId: String, mode: String) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.setRepeat(entityId, mode: mode)
    }

    /// Play media on a speaker. Delegates to MediaPlayerViewModel.
    func playMedia(entityId: String, contentId: String, contentType: String) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.playMedia(entityId: entityId, contentId: contentId, contentType: contentType)
    }

    func enqueueMedia(entityId: String, contentId: String, contentType: String) async {
        guard canPerformActions else { return }
        await mediaPlayerVM.enqueueMedia(entityId: entityId, contentId: contentId, contentType: contentType)
    }

    // MARK: - Spotify Delegation

    /// Search Spotify. Delegates to SpotifyBrowseViewModel.
    func searchSpotify(query: String, category: String) async -> [BrowseItem] {
        await spotifyBrowseVM.searchSpotify(query: query, category: category)
    }

    /// Browse Spotify content. Delegates to SpotifyBrowseViewModel.
    func browseMedia(contentId: String, contentType: String) async -> BrowseResult? {
        await spotifyBrowseVM.browseMedia(contentId: contentId, contentType: contentType)
    }

    /// Browse HA media root. Delegates to SpotifyBrowseViewModel.
    func browseMediaRoot(entityId: String) async -> BrowseResult? {
        await spotifyBrowseVM.browseMediaRoot(entityId: entityId)
    }

    /// Browse HA media. Delegates to SpotifyBrowseViewModel.
    func browseMediaHA(entityId: String, contentId: String, contentType: String) async -> BrowseResult? {
        await spotifyBrowseVM.browseMediaHA(entityId: entityId, contentId: contentId, contentType: contentType)
    }

    // MARK: - Camera Delegation

    /// Maps door entity IDs to their associated Ring camera event select entities.
    static let doorCameraMap: [String: String] = CameraViewModel.doorCameraMap

    /// Get filtered camera events. Delegates to CameraViewModel.
    func filteredCameraEvents(for eventSelectId: String) -> [String] {
        cameraVM.filteredCameraEvents(for: eventSelectId)
    }

    /// Find closest event via history. Delegates to CameraViewModel.
    func findClosestEventViaHistory(for doorId: String) async -> (options: [String], index: Int)? {
        let door = doorStatuses.first(where: { $0.id == doorId })
        return await cameraVM.findClosestEventViaHistory(for: doorId, lastOpenedAt: door?.lastOpenedAt)
    }

    /// Fetch door video. Delegates to CameraViewModel.
    func fetchDoorVideo(eventSelectId: String, option: String) async -> AVPlayer? {
        await cameraVM.fetchDoorVideo(eventSelectId: eventSelectId, option: option)
    }

    /// Select event option. Delegates to CameraViewModel.
    func selectEventOption(_ entityId: String, option: String) async {
        guard canPerformActions else { return }
        await cameraVM.selectEventOption(entityId, option: option)
    }

    /// Update door camera availability. Delegates to CameraViewModel.
    private func updateDoorCameraAvailability() {
        doorCameraAvailable = cameraVM.doorCameraAvailability(doorStatuses: doorStatuses)
    }

    // MARK: - Schedule-Aware Automations

    /// Refresh automation suggestions based on today's calendar events.
    func refreshAutomations(calendarEvents: [CalendarEventDTO]) {
        suggestedAutomations = automationService.checkAutomations(
            events: calendarEvents
        ) { [weak self] domain, service, data in
            guard let self else { return }
            await self.performAction(domain: domain, service: service, data: data)
        }
    }

    /// Dismiss a suggested automation (won't reappear for 24h).
    func dismissAutomation(_ automation: SuggestedAutomation) {
        automationService.dismiss(automation)
        suggestedAutomations.removeAll { $0.id == automation.id }
    }

    /// Set operation mode for a water_heater entity (e.g. "eco", "on", "off").
    func setWaterHeaterMode(_ entityId: String, mode: String) async {
        await performAction(domain: "water_heater", service: "set_operation_mode", data: [
            "entity_id": entityId,
            "operation_mode": mode,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, state: mode)
        }
    }

    /// Set preset mode for a climate entity (e.g. "boost", "Schedule").
    func setPresetMode(_ entityId: String, preset: String) async {
        await performAction(domain: "climate", service: "set_preset_mode", data: [
            "entity_id": entityId,
            "preset_mode": preset,
        ]) { [self] in
            haClient.updateEntityOptimistically(entityId, attributeUpdates: [
                "preset_mode": .string(preset)
            ])
        }
    }

    // MARK: - Scenes & Scripts

    private static let favoriteSceneKey = "favorite_scenes"

    /// Activate a scene or script entity.
    func activateScene(_ entityId: String) async {
        let domain = String(entityId.prefix(while: { $0 != "." }))
        await performAction(domain: domain, service: "turn_on", data: ["entity_id": entityId])

        // Show toast
        toastMessage = "Activated: \(scenes.first(where: { $0.entityId == entityId })?.displayName ?? entityId)"
        toastIsWarning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.toastMessage = nil
        }
    }

    /// Toggle a scene/script entity as a favorite (persisted via UserDefaults).
    func toggleSceneFavorite(_ entityId: String) {
        var favorites = Set(UserDefaults.standard.stringArray(forKey: Self.favoriteSceneKey) ?? [])
        if favorites.contains(entityId) {
            favorites.remove(entityId)
        } else {
            favorites.insert(entityId)
        }
        UserDefaults.standard.set(Array(favorites), forKey: Self.favoriteSceneKey)
        computeScenes()
    }

    /// Build the scenes list from HA entities (scene.* and script.*).
    private func computeScenes(from entities: [HAEntity]? = nil) {
        let favorites = Set(UserDefaults.standard.stringArray(forKey: Self.favoriteSceneKey) ?? [])
        let sourceEntities = entities ?? Array(haClient.entities.values)

        var sceneList: [SceneInfo] = []
        for entity in sourceEntities {
            let entityId = entity.entityId
            guard entityId.hasPrefix("scene.") || entityId.hasPrefix("script.") else { continue }
            let domain = String(entityId.prefix(while: { $0 != "." }))
            let name = entity.friendlyName != entityId
                ? entity.friendlyName
                : entityId.replacingOccurrences(of: "\(domain).", with: "").replacingOccurrences(of: "_", with: " ").capitalized
            let icon = domain == "scene" ? "play.circle" : "bolt.circle"

            sceneList.append(SceneInfo(
                id: entityId,
                entityId: entityId,
                displayName: name,
                icon: icon,
                domain: domain,
                isFavorite: favorites.contains(entityId)
            ))
        }

        // Sort: favorites first, then alphabetical
        sceneList.sort { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.displayName < b.displayName
        }

        scenes = sceneList
    }

    // MARK: - Status Banner Computed Properties

    /// Average temperature across all heating rooms, formatted for the status banner.
    var statusTemperature: String? {
        let temps = heatingRooms.compactMap(\.currentTemp)
        guard !temps.isEmpty else { return nil }
        let avg = temps.reduce(0, +) / Double(temps.count)
        return String(format: "%.1f\u{00B0}C", avg)
    }

    /// Door summary string for the status banner.
    var statusDoorSummary: String {
        let openDoors = doorStatuses.filter(\.isOpen)
        if openDoors.isEmpty { return "ALL CLOSED" }
        return openDoors.map(\.name).joined(separator: ", ").uppercased() + " OPEN"
    }

    /// Sonos now-playing summary for the status banner, or nil if nothing is playing.
    var statusSonosSummary: String? {
        let playing = sonosPlayers.first(where: { $0.state == "playing" })
        if let playing {
            return "\u{266A} \(playing.mediaTitle ?? playing.name)"
        }
        return nil
    }

    // MARK: - Derived State Computation

    private func computeDerivedState() {
        var climateEntities: [HAEntity] = []
        var lightEntities: [HAEntity] = []
        var binarySensorEntities: [HAEntity] = []
        var mediaPlayerEntities: [HAEntity] = []
        let allEntities = Array(haClient.entities.values)

        for entity in allEntities {
            switch entity.domain {
            case "climate": climateEntities.append(entity)
            case "light": lightEntities.append(entity)
            case "binary_sensor": binarySensorEntities.append(entity)
            case "media_player": mediaPlayerEntities.append(entity)
            default: break
            }
        }
        let entityOrder: (HAEntity, HAEntity) -> Bool = { $0.entityId < $1.entityId }
        climateEntities.sort(by: entityOrder)
        lightEntities.sort(by: entityOrder)
        binarySensorEntities.sort(by: entityOrder)
        mediaPlayerEntities.sort(by: entityOrder)

        // Heating
        heatingRooms = climateEntities.map { entity in
            HeatingRoom(
                id: entity.entityId,
                name: entity.friendlyName,
                currentTemp: entity.currentTemperature,
                targetTemp: entity.targetTemperature,
                isHeating: entity.hvacAction == "heating"
            )
        }

        // Lights
        totalLights = lightEntities.count
        lightsOn = lightEntities.map { entity in
            LightInfo(
                id: entity.entityId,
                name: entity.friendlyName,
                isOn: entity.isOn,
                brightness: entity.brightness
            )
        }

        // Doors -- only physical contact sensors (front + back door)
        // Preserve existing history data when rebuilding
        let existingDoorHistory = Dictionary(uniqueKeysWithValues: doorStatuses.map { ($0.id, $0) })
        let doorEntityIds: Set<String> = ["binary_sensor.example_e1938001", "binary_sensor.example_cadfe0f1"]
        doorStatuses = binarySensorEntities
            .filter { doorEntityIds.contains($0.entityId) }
            .map { entity in
                var status = DoorStatus(
                    id: entity.entityId,
                    name: entity.friendlyName,
                    isOpen: entity.isOn
                )
                if let existing = existingDoorHistory[entity.entityId] {
                    status.lastOpenedAt = existing.lastOpenedAt
                    status.openDuration = existing.openDuration
                    status.isStillOpen = existing.isStillOpen
                }
                return status
            }

        // Sonos
        sonosPlayers = mediaPlayerEntities
            .filter { $0.entityId.contains("sonos") }
            .map { entity in
                SonosPlayer(
                    id: entity.entityId,
                    name: entity.friendlyName,
                    state: entity.state,
                    mediaTitle: entity.mediaTitle,
                    mediaArtist: entity.mediaArtist
                )
            }

        // Appliances (sensors with specific entity IDs)
        let applianceIds = ["sensor.example_5e6551b9", "sensor.example_eeb348c9"]
        appliances = applianceIds.compactMap { id in
            guard let entity = haClient.entity(id) else { return nil }
            return ApplianceStatus(
                id: entity.entityId,
                name: entity.friendlyName,
                status: entity.state
            )
        }

        // Scenes & Scripts
        computeScenes(from: allEntities)

        // Also update sub-VM state
        mediaPlayerVM.computeSonosPlayers(from: mediaPlayerEntities)

        // Check for anomalies via AnomalyService
        anomalyService.checkForAnomalies(
            scenePhase: scenePhase,
            doorStatuses: doorStatuses,
            entities: haClient.entities,
            heatingRooms: heatingRooms
        )

    }

    // MARK: - Room Light Toggle

    /// Toggle all lights in a room. If any light is on, turn all off; otherwise turn all on.
    func toggleRoomLights(room: FloorPlanRoom) async {
        let lightEntityIds = room.lightEntities
        guard !lightEntityIds.isEmpty else { return }

        let anyOn = lightEntityIds.contains { entityId in
            haClient.entity(entityId)?.isOn == true
        }
        let service = anyOn ? "turn_off" : "turn_on"

        for entityId in lightEntityIds {
            let newState = anyOn ? "off" : "on"
            await performAction(domain: "light", service: service, data: ["entity_id": entityId]) { [self] in
                haClient.updateEntityOptimistically(entityId, state: newState)
            }
        }
    }

    // MARK: - Speaker Grouping

    /// Join a speaker to another speaker's group.
    func joinSpeakerGroup(entityId: String, targetEntityId: String) async {
        await performAction(domain: "media_player", service: "join", data: [
            "entity_id": targetEntityId,
            "group_members": [entityId],
        ])
    }

    /// Remove a speaker from its current group.
    func unjoinSpeaker(entityId: String) async {
        await performAction(domain: "media_player", service: "unjoin", data: [
            "entity_id": entityId,
        ])
    }

    /// Group all Sonos speakers together under the first available speaker.
    func groupAllSpeakers() async {
        let speakers = haClient.entities(inDomain: "media_player")
            .filter { !$0.entityId.contains("spotify") }
        guard let primary = speakers.first else { return }
        let others = speakers.dropFirst().map(\.entityId)
        guard !others.isEmpty else { return }

        await performAction(domain: "media_player", service: "join", data: [
            "entity_id": primary.entityId,
            "group_members": others,
        ])
    }

    /// Send a TTS message to a specific speaker.
    func sendTTS(entityId: String, message: String) async {
        await performAction(domain: "tts", service: "speak", data: [
            "entity_id": entityId,
            "message": message,
        ])
    }

    // MARK: - House Mode

    /// The mode entity selected by the backend capability manifest.
    var houseModeEntity: HAEntity? {
        guard let entityId = manifest?.modeSelector?.entityId else { return nil }
        return haClient.entities[entityId]
    }

    /// Set one mode chosen and confirmed by the user; never infer or cycle it.
    func setHouseMode(_ option: String) async {
        guard let entity = houseModeEntity else { return }

        guard let selector = manifest?.modeSelector else { return }
        let options = selector.options

        guard options.contains(option), option != entity.state else { return }

        await performAction(domain: entity.domain, service: "select_option", data: [
            "entity_id": entity.entityId,
            "option": option,
        ]) { [self] in
            haClient.updateEntityOptimistically(entity.entityId, state: option)
        }
    }

    // MARK: - Full Door History

    /// Fetch all door open/close events for the last 24 hours.
    func fetchFullDoorHistory(entityId: String) async -> [HAClient.DoorEvent] {
        await haClient.fetchFullDoorHistory(entityId: entityId)
    }
}
