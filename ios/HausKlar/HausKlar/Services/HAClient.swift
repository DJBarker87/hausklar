import Foundation
import ImageIO
import UIKit

struct HomeSnapshotDTO: Codable {
    let configured: Bool
    let available: Bool
    let entities: [HomeEntityDTO]
    let manifest: HomeManifestDTO?
    let sitrep: HomeSitrepDTO?
}

struct HomeTemperatureHistoryDTO: Codable, Equatable {
    let entityId: String
    let unit: String?
    let hours: Int
    let points: [HomeTemperatureHistoryPointDTO]
}

struct HomeTemperatureHistoryPointDTO: Codable, Equatable {
    let recordedAt: String
    let temperature: Double
    let targetTemperature: Double?
    let heating: Bool
}

struct HomeManifestDTO: Codable, Equatable {
    let rooms: [HomeManifestRoomDTO]
    let entities: [HomeManifestEntityDTO]
    let favouriteEntityIds: [String]
    let modeSelector: HomeModeSelectorDTO?
    let broadActionScopes: [String]
    let advancedFeatures: [String]
}

struct HomeManifestRoomDTO: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let floor: Int
    let entityIds: [String]
    let lightEntityIds: [String]
}

struct HomeManifestEntityDTO: Codable, Equatable, Identifiable {
    var id: String { entityId }
    let entityId: String
    let name: String
    let domain: String
    let roomId: String?
    let roomName: String?
    let controlKind: String
    let capabilities: [String]
    let favourite: Bool
    let advanced: Bool
}

struct HomeModeSelectorDTO: Codable, Equatable {
    let entityId: String
    let name: String
    let current: String
    let options: [String]
}

struct HomeSitrepDTO: Codable, Equatable {
    let tone: String
    let headline: String
    let summary: String
    let exceptions: [HomeExceptionDTO]
    let updatedAt: String
}

struct HomeExceptionDTO: Codable, Equatable, Identifiable {
    let id: String
    let severity: String
    let title: String
    let detail: String
    let entityId: String?
    let roomId: String?
}

struct HomeEntityDTO: Codable {
    let entityId: String
    let name: String
    let state: String
    let deviceClass: String?
    let unitOfMeasurement: String?
    let currentTemperature: Double?
    let temperature: Double?
    let hvacAction: String?
    let brightness: Int?
    let mediaTitle: String?
    let mediaArtist: String?
    let volumeLevel: Double?
    let isVolumeMuted: Bool?
    let shuffle: Bool?
    let `repeat`: String?
    let mediaAlbumName: String?
    let mediaDuration: Double?
    let mediaPosition: Double?
    let mediaPositionUpdatedAt: String?
    let entityPicture: String?
    let options: [String]?
    let batteryLevel: Int?
    let source: String?
    let operationMode: String?
    let operationList: [String]?
    let groupMembers: [String]?
    let hvacModes: [String]?
    let presetModes: [String]?
    let presetMode: String?
    let minTemp: Double?
    let maxTemp: Double?
    let lastChanged: String?
    let lastUpdated: String?

    func asEntity() -> HAEntity {
        var attributes: [String: JSONValue] = ["friendly_name": .string(name)]
        func set(_ key: String, _ value: String?) {
            if let value { attributes[key] = .string(value) }
        }
        func set(_ key: String, _ value: Double?) {
            if let value { attributes[key] = .double(value) }
        }
        func set(_ key: String, _ value: Int?) {
            if let value { attributes[key] = .int(value) }
        }
        func set(_ key: String, _ value: Bool?) {
            if let value { attributes[key] = .bool(value) }
        }
        func set(_ key: String, _ value: [String]?) {
            if let value { attributes[key] = .array(value.map(JSONValue.string)) }
        }

        set("device_class", deviceClass)
        set("unit_of_measurement", unitOfMeasurement)
        set("current_temperature", currentTemperature)
        set("temperature", temperature)
        set("hvac_action", hvacAction)
        set("brightness", brightness)
        set("media_title", mediaTitle)
        set("media_artist", mediaArtist)
        set("volume_level", volumeLevel)
        set("is_volume_muted", isVolumeMuted)
        set("shuffle", shuffle)
        set("repeat", `repeat`)
        set("media_album_name", mediaAlbumName)
        set("media_duration", mediaDuration)
        set("media_position", mediaPosition)
        set("media_position_updated_at", mediaPositionUpdatedAt)
        set("entity_picture", entityPicture)
        set("options", options)
        set("battery_level", batteryLevel)
        set("source", source)
        set("operation_mode", operationMode)
        set("operation_list", operationList)
        set("group_members", groupMembers)
        set("hvac_modes", hvacModes)
        set("preset_modes", presetModes)
        set("preset_mode", presetMode)
        set("min_temp", minTemp)
        set("max_temp", maxTemp)

        return HAEntity(
            entityId: entityId,
            state: state,
            attributes: attributes,
            lastChanged: lastChanged ?? "1970-01-01T00:00:00Z",
            lastUpdated: lastUpdated ?? lastChanged ?? "1970-01-01T00:00:00Z"
        )
    }
}

struct HomeServiceRequestDTO: Encodable {
    let domain: String
    let service: String
    let data: [String: JSONValue]
    let returnResponse: Bool
}

private struct HomeFavouritesRequestDTO: Encodable {
    let entityIds: [String]
}

private struct HomeFavouritesResponseDTO: Decodable {
    let entityIds: [String]
}

struct HomeBroadActionChoice: Equatable {
    let action: String
    let scope: String
    let roomId: String?
}

private struct HomeBroadActionRequestDTO: Encodable {
    let action: String
    let scope: String
    let roomId: String?
    let confirmed: Bool
}

private struct HomeBroadActionResponseDTO: Decodable {
    let entityIds: [String]
}

/// Authenticated adapter for the HausKlar Home Assistant proxy.
/// The HA URL and long-lived token never enter the iOS process.
@MainActor
final class HAClient: ObservableObject {
    static let shared = HAClient()

    @Published var entities: [String: HAEntity] = [:]
    @Published var zhaLqi: [String: Int] = [:]
    @Published var isConnected: Bool = false
    @Published var lastFetch: Date?
    @Published var lastError: String?
    @Published var isPaused: Bool = false
    @Published private(set) var isDemoMode: Bool = false
    @Published private(set) var manifest: HomeManifestDTO?
    @Published private(set) var sitrep: HomeSitrepDTO?

    private var backendConfigured = false
    private var pollingTask: Task<Void, Never>?

    /// In-memory image cache for album art, camera snapshots, etc.
    private let imageCache = NSCache<NSString, UIImage>()

    private init() {
        imageCache.countLimit = 50
        imageCache.totalCostLimit = 20 * 1024 * 1024 // 20 MB
    }

    // MARK: - Configuration

    var isConfigured: Bool { backendConfigured }

    func setBackendConfigured(_ configured: Bool) {
        if configured, isDemoMode {
            discardDisplayedState()
        }
        backendConfigured = configured
        if !configured {
            isConnected = false
        }
    }

    // MARK: - API Methods

    /// Fetch the backend's sanitized Home Assistant snapshot.
    func fetchAllStates() async throws {
        guard backendConfigured else {
            isConnected = false
            lastError = HAClientError.notConfigured.localizedDescription
            throw HAClientError.notConfigured
        }

        do {
            let snapshot: HomeSnapshotDTO = try await APIClient.shared.get("/home/status", bypassCache: true)
            try apply(snapshot: snapshot)
        } catch {
            isConnected = false
            if lastError == nil {
                lastError = error.localizedDescription
            }
            throw error
        }
    }

    /// Apply a sanitized backend snapshot without ever manufacturing replacement state.
    /// Kept internal so focused tests can verify live/unavailable transitions without a network.
    func apply(snapshot: HomeSnapshotDTO, fetchedAt: Date = Date()) throws {
        if isDemoMode {
            discardDisplayedState()
        }
        backendConfigured = snapshot.configured
        guard snapshot.configured else {
            discardDisplayedState()
            lastError = HAClientError.notConfigured.localizedDescription
            throw HAClientError.notConfigured
        }
        guard snapshot.available else {
            isConnected = false
            lastError = "Home Assistant is unavailable through HausKlar."
            throw HAClientError.unavailable
        }
        let newEntities = Dictionary(
            uniqueKeysWithValues: snapshot.entities.map { entity in
                let converted = entity.asEntity()
                return (converted.entityId, converted)
            }
        )
        if newEntities != entities {
            entities = newEntities
        }
        manifest = snapshot.manifest
        sitrep = snapshot.sitrep
        isConnected = true
        lastFetch = fetchedAt
        lastError = nil
    }

    /// Refresh the backend snapshot and return one entity from it.
    func fetchSingleEntityState(_ entityId: String) async throws -> HAEntity {
        guard backendConfigured else { throw HAClientError.notConfigured }
        try await fetchAllStates()
        guard let entity = entities[entityId] else { throw HAClientError.notFound }
        return entity
    }

    static func serviceRequest(
        domain: String,
        service: String,
        data: [String: Any],
        returnResponse: Bool
    ) throws -> HomeServiceRequestDTO {
        guard JSONSerialization.isValidJSONObject(data) else {
            throw HAClientError.invalidRequest
        }
        let encoded = try JSONSerialization.data(withJSONObject: data)
        let values = try JSONDecoder().decode([String: JSONValue].self, from: encoded)
        return HomeServiceRequestDTO(
            domain: domain,
            service: service,
            data: values,
            returnResponse: returnResponse
        )
    }

    /// Call an allowlisted Home Assistant service through the HausKlar backend.
    func callService(domain: String, service: String, data: [String: Any] = [:]) async throws {
        guard backendConfigured else { throw HAClientError.notConfigured }
        let request = try Self.serviceRequest(
            domain: domain,
            service: service,
            data: data,
            returnResponse: false
        )
        _ = try await APIClient.shared.postData("/home/services", body: request)
    }

    func saveHomeFavourites(_ entityIds: [String]) async throws -> [String] {
        let response: HomeFavouritesResponseDTO = try await APIClient.shared.put(
            "/home/favourites",
            body: HomeFavouritesRequestDTO(entityIds: entityIds)
        )
        try await fetchAllStates()
        return response.entityIds
    }

    func performBroadAction(_ choice: HomeBroadActionChoice) async throws -> [String] {
        let response: HomeBroadActionResponseDTO = try await APIClient.shared.post(
            "/home/broad-actions",
            body: HomeBroadActionRequestDTO(
                action: choice.action,
                scope: choice.scope,
                roomId: choice.roomId,
                confirmed: true
            )
        )
        try await fetchAllStates()
        return response.entityIds
    }

    /// Return a cached entity image. Remote images require a future backend proxy.
    func fetchEntityPicture(path: String) async -> UIImage? {
        let cacheKey = path as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        return nil
    }

    /// Call a HA service and return the response data (for services that support return_response).
    func callServiceWithResponse(domain: String, service: String, data: [String: Any] = [:]) async throws -> [String: Any] {
        guard backendConfigured else { throw HAClientError.notConfigured }
        let request = try Self.serviceRequest(
            domain: domain,
            service: service,
            data: data,
            returnResponse: true
        )
        let responseData = try await APIClient.shared.postData("/home/services", body: request)
        return (try JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }

    /// Fetch a bounded camera snapshot through the authenticated HausKlar API.
    func fetchSnapshot(entityId: String) async -> UIImage? {
        guard Self.validCameraEntityID(entityId) else { return nil }
        do {
            let data = try await APIClient.shared.downloadData(
                "/home/cameras/\(entityId)/snapshot",
                policy: .image(maximumBytes: 5 * 1_024 * 1_024),
                cachePolicy: .networkOnly
            )
            guard data.count <= 5 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  Self.safeImageDimensions(
                    width: width.int64Value,
                    height: height.int64Value
                  ),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2_560,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                  ) else { return nil }
            let image = UIImage(cgImage: thumbnail)
            cacheImage(image, forKey: NSString(string: entityId))
            return image
        } catch {
            return nil
        }
    }

    static func validCameraEntityID(_ value: String) -> Bool {
        guard value.hasPrefix("camera."), value.count <= 200 else { return false }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces.allSatisfy { part in
            !part.isEmpty && part.allSatisfy {
                $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
            }
        }
    }

    static func safeImageDimensions(width: Int64, height: Int64) -> Bool {
        guard width > 0, height > 0, width <= 8_192, height <= 8_192 else {
            return false
        }
        return UInt64(width) * UInt64(height) <= 24_000_000
    }

    /// Store an image in the shared cache (used for pre-fetching camera snapshots).
    func cacheImage(_ image: UIImage, forKey key: NSString) {
        let cost = image.jpegData(compressionQuality: 1.0)?.count ?? 0
        imageCache.setObject(image, forKey: key, cost: cost)
    }

    /// Retrieve a cached image by key.
    func cachedImage(forKey key: NSString) -> UIImage? {
        imageCache.object(forKey: key)
    }

    // MARK: - ZHA LQI

    /// LQI is omitted until the authenticated HausKlar snapshot exposes it.
    func fetchZhaLqi() async {
        zhaLqi = [:]
    }

    // MARK: - Door History

    struct DoorEvent {
        let openedAt: Date
        let closedAt: Date?
        var duration: TimeInterval? {
            guard let closed = closedAt else { return nil }
            return closed.timeIntervalSince(openedAt)
        }
        var isStillOpen: Bool { closedAt == nil }
    }

    /// Door history requires a future authenticated HausKlar proxy.
    func fetchFullDoorHistory(entityId: String) async -> [DoorEvent] {
        []
    }

    /// The latest door event is unavailable until the backend exposes history.
    func fetchDoorHistory(entityId: String) async -> DoorEvent? {
        nil
    }

    // MARK: - Event Select History

    struct EventSelectHistoryEntry {
        let state: String
        let timestamp: Date
    }

    /// Select history is unavailable until the backend exposes it.
    func fetchEventSelectHistory(entityId: String) async -> [EventSelectHistoryEntry] {
        []
    }

    // MARK: - Time-Series History (via config-api)

    struct HistoryReading: Sendable {
        let ts: Double
        let state: String
        let attributes: [String: JSONValue]

        var date: Date { Date(timeIntervalSince1970: ts) }

        func attrDouble(_ key: String) -> Double? {
            guard let value = attributes[key] else { return nil }
            return value.doubleValue ?? value.stringValue.flatMap(Double.init)
        }
    }

    struct TemperatureHistoryPoint: Identifiable, Sendable, Equatable {
        let recordedAt: Date
        let temperature: Double
        let targetTemperature: Double?
        let heating: Bool

        var id: Date { recordedAt }
    }

    /// Fetch one bounded, sanitised 24-hour room-temperature series.
    func fetchTemperatureHistory(entityId: String) async throws -> [TemperatureHistoryPoint] {
        guard Self.validEntityID(entityId) else { throw HAClientError.invalidRequest }
        if isDemoMode {
            return Self.generateDemoHistory(entityId: entityId, hours: 24).compactMap { reading in
                let temperature = reading.attrDouble("current_temperature") ?? Double(reading.state)
                guard let temperature else { return nil }
                return TemperatureHistoryPoint(
                    recordedAt: reading.date,
                    temperature: temperature,
                    targetTemperature: reading.attrDouble("temperature"),
                    heating: reading.attributes["hvac_action"]?.stringValue == "heating"
                )
            }
        }
        guard backendConfigured else { throw HAClientError.notConfigured }
        let response: HomeTemperatureHistoryDTO = try await APIClient.shared.get(
            "/home/temperature-history/\(entityId)",
            bypassCache: true
        )
        guard response.entityId == entityId, response.hours == 24 else {
            throw HAClientError.invalidResponse
        }
        return response.points.compactMap { point in
            guard let recordedAt = ISODateParser.parse(point.recordedAt),
                  (-80...80).contains(point.temperature)
            else { return nil }
            return TemperatureHistoryPoint(
                recordedAt: recordedAt,
                temperature: point.temperature,
                targetTemperature: point.targetTemperature,
                heating: point.heating
            )
        }
    }

    static func validEntityID(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.count <= 200 && pieces.count == 2 && pieces.allSatisfy { part in
            !part.isEmpty && part.allSatisfy {
                $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
            }
        }
    }

    /// Return history only in explicit demo mode; live history awaits a backend capability.
    func fetchHistory(entityId: String, hours: Int = 24) async -> [HistoryReading] {
        isDemoMode ? Self.generateDemoHistory(entityId: entityId, hours: hours) : []
    }

    // MARK: - Demo History Data

    /// Generates realistic-looking demo history data for App Store review.
    private static func generateDemoHistory(entityId: String, hours: Int) -> [HistoryReading] {
        let now = Date()
        let interval: TimeInterval = hours <= 6 ? 300 : hours <= 24 ? 600 : hours <= 168 ? 1800 : 3600
        let count = Int(Double(hours) * 3600 / interval)
        let seed = entityId.hashValue

        if entityId.hasPrefix("climate.") {
            return generateClimateHistory(count: count, interval: interval, now: now, seed: seed)
        } else if entityId.contains("_temperature") {
            return generateTemperatureHistory(count: count, interval: interval, now: now, seed: seed)
        } else if entityId.contains("_humidity") {
            return generateHumidityHistory(count: count, interval: interval, now: now, seed: seed)
        } else if entityId.hasPrefix("binary_sensor.") || entityId.hasPrefix("switch.") || entityId.hasPrefix("light.") {
            return generateBinaryHistory(count: count, interval: interval, now: now, seed: seed)
        } else if entityId.hasPrefix("weather.") {
            return generateWeatherHistory(count: count, interval: interval, now: now, seed: seed)
        } else if entityId.contains("battery") {
            return generateBatteryHistory(count: count, interval: interval, now: now, seed: seed)
        } else if entityId.contains("power") || entityId.contains("energy") {
            return generatePowerHistory(count: count, interval: interval, now: now, seed: seed)
        } else {
            return generateTemperatureHistory(count: count, interval: interval, now: now, seed: seed)
        }
    }

    /// Seeded pseudo-random for deterministic demo data per entity.
    private static func seededRandom(_ seed: Int, _ index: Int) -> Double {
        let x = sin(Double(seed &+ index &* 7919)) * 43758.5453
        return x - x.rounded(.down)
    }

    private static func generateClimateHistory(count: Int, interval: TimeInterval, now: Date, seed: Int) -> [HistoryReading] {
        // TRV: current temp fluctuates around target, target changes on schedule
        var readings: [HistoryReading] = []
        let baseTarget = 20.0 + seededRandom(seed, 0) * 2 // 20-22
        for i in 0..<count {
            let ts = now.addingTimeInterval(-Double(count - i) * interval).timeIntervalSince1970
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: ts))
            // Lower target at night (22:00-06:00)
            let target = (hour >= 22 || hour < 6) ? baseTarget - 3 : baseTarget
            let noise = seededRandom(seed, i) * 1.0 - 0.5
            let current = target + noise + sin(Double(i) * 0.1) * 0.8
            readings.append(HistoryReading(
                ts: ts,
                state: String(format: "%.1f", current),
                attributes: [
                    "current_temperature": .double(current),
                    "temperature": .double(target),
                    "hvac_action": .string(current < target ? "heating" : "idle"),
                ]
            ))
        }
        return readings
    }

    private static func generateTemperatureHistory(count: Int, interval: TimeInterval, now: Date, seed: Int) -> [HistoryReading] {
        var readings: [HistoryReading] = []
        let baseTemp = 18.0 + seededRandom(seed, 0) * 5 // 18-23
        for i in 0..<count {
            let ts = now.addingTimeInterval(-Double(count - i) * interval).timeIntervalSince1970
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: ts))
            let dayVariation = (hour >= 8 && hour <= 20) ? 1.5 : -1.0
            let noise = seededRandom(seed, i) * 0.6 - 0.3
            let temp = baseTemp + dayVariation + noise + sin(Double(i) * 0.05) * 0.5
            readings.append(HistoryReading(ts: ts, state: String(format: "%.1f", temp), attributes: [:]))
        }
        return readings
    }

    private static func generateHumidityHistory(count: Int, interval: TimeInterval, now: Date, seed: Int) -> [HistoryReading] {
        var readings: [HistoryReading] = []
        let baseHum = 40.0 + seededRandom(seed, 0) * 20 // 40-60%
        for i in 0..<count {
            let ts = now.addingTimeInterval(-Double(count - i) * interval).timeIntervalSince1970
            let noise = seededRandom(seed, i) * 4.0 - 2.0
            let hum = min(80, max(25, baseHum + noise + sin(Double(i) * 0.08) * 3))
            readings.append(HistoryReading(ts: ts, state: String(format: "%.1f", hum), attributes: [:]))
        }
        return readings
    }

    private static func generateBinaryHistory(count: Int, interval: TimeInterval, now: Date, seed: Int) -> [HistoryReading] {
        var readings: [HistoryReading] = []
        var isOn = false
        for i in 0..<count {
            let ts = now.addingTimeInterval(-Double(count - i) * interval).timeIntervalSince1970
            // Toggle with ~10% probability each interval
            if seededRandom(seed, i) < 0.1 { isOn.toggle() }
            readings.append(HistoryReading(ts: ts, state: isOn ? "on" : "off", attributes: [:]))
        }
        return readings
    }

    private static func generateWeatherHistory(count: Int, interval: TimeInterval, now: Date, seed: Int) -> [HistoryReading] {
        var readings: [HistoryReading] = []
        for i in 0..<count {
            let ts = now.addingTimeInterval(-Double(count - i) * interval).timeIntervalSince1970
            let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: ts))
            let dayWarm = (hour >= 10 && hour <= 16) ? 3.0 : 0.0
            let noise = seededRandom(seed, i) * 1.0 - 0.5
            let temp = 5.0 + dayWarm + noise + sin(Double(i) * 0.03) * 2
            readings.append(HistoryReading(
                ts: ts,
                state: "cloudy",
                attributes: [
                    "temperature": .double(temp),
                    "humidity": .double(65.0 + noise * 5),
                ]
            ))
        }
        return readings
    }

    private static func generateBatteryHistory(count: Int, interval: TimeInterval, now: Date, seed: Int) -> [HistoryReading] {
        var readings: [HistoryReading] = []
        var level = 95.0 + seededRandom(seed, 0) * 5
        for i in 0..<count {
            let ts = now.addingTimeInterval(-Double(count - i) * interval).timeIntervalSince1970
            level -= seededRandom(seed, i) * 0.3
            if level < 20 { level = 95 + seededRandom(seed, i) * 5 } // "recharged"
            readings.append(HistoryReading(ts: ts, state: String(format: "%.0f", level), attributes: [:]))
        }
        return readings
    }

    private static func generatePowerHistory(count: Int, interval: TimeInterval, now: Date, seed: Int) -> [HistoryReading] {
        var readings: [HistoryReading] = []
        for i in 0..<count {
            let ts = now.addingTimeInterval(-Double(count - i) * interval).timeIntervalSince1970
            let base = 150.0 + seededRandom(seed, i) * 200
            let spike = seededRandom(seed, i + 1000) < 0.05 ? 800.0 : 0.0
            readings.append(HistoryReading(ts: ts, state: String(format: "%.0f", base + spike), attributes: [:]))
        }
        return readings
    }

    // MARK: - Polling

    /// Pause polling — fetches are skipped until `resumePolling()` is called.
    func pausePolling() {
        isPaused = true
    }

    /// Resume polling after a pause.
    func resumePolling() {
        isPaused = false
    }

    /// Start polling HA for state updates at the given interval.
    func startPolling(interval: TimeInterval = 10) {
        stopPolling()
        pollingTask = Task { [weak self] in
            var lqiCounter = 0
            while !Task.isCancelled {
                // Skip fetch if polling is paused
                if self?.isPaused != true {
                    do {
                        try await self?.fetchAllStates()
                    } catch {
                        self?.isConnected = false
                        self?.lastError = error.localizedDescription
                    }
                    // Fetch ZHA LQI every ~60s (every 6th poll at 10s interval)
                    lqiCounter += 1
                    if lqiCounter == 1 || lqiCounter % 6 == 0 {
                        await self?.fetchZhaLqi()
                    }
                }
                do {
                    try await Task.sleep(
                        nanoseconds:UInt64(interval * 1_000_000_000)
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self?.lastError="Home refresh scheduling stopped unexpectedly."
                    return
                }
            }
        }
    }

    /// Stop polling.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Optimistic Updates

    /// Update an entity's state/attributes locally for instant UI feedback.
    /// The real state will be confirmed on the next poll or background refresh.
    func updateEntityOptimistically(_ entityId: String, state: String? = nil, attributeUpdates: [String: JSONValue] = [:]) {
        guard let entity = entities[entityId] else { return }
        let now = ISODateParser.string(from: Date())
        var newAttrs = entity.attributes
        for (key, value) in attributeUpdates { newAttrs[key] = value }
        entities[entityId] = HAEntity(
            entityId: entity.entityId,
            state: state ?? entity.state,
            attributes: newAttrs,
            lastChanged: state != nil ? now : entity.lastChanged,
            lastUpdated: now
        )
    }

    private var backgroundRefreshTask: Task<Void, Never>?

    /// Schedule a background refresh after a delay, cancelling any pending one.
    func scheduleBackgroundRefresh(delay: TimeInterval = 2.0) {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds:UInt64(delay * 1_000_000_000)
                )
            } catch is CancellationError {
                return
            } catch {
                self?.lastError="The scheduled Home refresh could not start."
                return
            }
            guard !Task.isCancelled,let self else { return }
            do {
                try await self.fetchAllStates()
            } catch is CancellationError {
                return
            } catch {
                self.isConnected=false
                self.lastError=error.localizedDescription
            }
        }
    }

    // MARK: - Convenience

    /// Get a single entity by ID.
    func entity(_ id: String) -> HAEntity? {
        entities[id]
    }

    /// Get all entities matching a domain (e.g. "light", "climate").
    func entities(inDomain domain: String) -> [HAEntity] {
        entities.values.filter { $0.domain == domain }.sorted { $0.entityId < $1.entityId }
    }

    // MARK: - Explicit Demo Data

    /// Enter explicit demo mode and load realistic sample data.
    /// Populates entities with sample HA states so the Home tab renders all widget cards.
    func loadDemoData() {
        stopPolling()
        backendConfigured = false
        isDemoMode = true
        manifest = nil
        sitrep = nil
        var demo: [String: HAEntity] = [:]
        let now = ISODateParser.string(from: Date())

        let climateRooms: [(String, String, Double, Double, String)] = [
            ("climate.example_dfadd42f", "Living Room", 20.5, 21.0, "heating"),
            ("climate.example_9feafd80", "Kitchen", 19.8, 20.0, "idle"),
            ("climate.example_5b2bd3d4", "Bedroom", 18.2, 19.0, "heating"),
            ("climate.example_a93d986a", "Office", 21.1, 21.0, "idle"),
        ]
        for (id, name, current, target, action) in climateRooms {
            demo[id] = HAEntity(
                entityId: id, state: "heat",
                attributes: [
                    "friendly_name": .string(name),
                    "current_temperature": .double(current),
                    "temperature": .double(target),
                    "hvac_action": .string(action),
                ],
                lastChanged: now, lastUpdated: now
            )
        }

        let lights: [(String, String, Bool, Int?)] = [
            ("light.example_d7ab5b9b", "Hallway", true, 180),
            ("light.example_ff6f3185", "Living Room", true, 255),
            ("light.example_3f2a461f", "Kitchen", false, nil),
            ("light.example_3cf6e630", "Bedroom", false, nil),
            ("light.example_ab6b8df0", "Office", true, 200),
        ]
        for (id, name, isOn, brightness) in lights {
            var attrs: [String: JSONValue] = ["friendly_name": .string(name)]
            if let b = brightness { attrs["brightness"] = .int(b) }
            demo[id] = HAEntity(
                entityId: id, state: isOn ? "on" : "off",
                attributes: attrs,
                lastChanged: now, lastUpdated: now
            )
        }

        let doors: [(String, String, Bool)] = [
            ("binary_sensor.example_e1938001", "Front Door", false),
            ("binary_sensor.example_cadfe0f1", "Back Door", false),
        ]
        for (id, name, isOpen) in doors {
            demo[id] = HAEntity(
                entityId: id, state: isOpen ? "on" : "off",
                attributes: ["friendly_name": .string(name)],
                lastChanged: now, lastUpdated: now
            )
        }

        demo["media_player.example_0602377b"] = HAEntity(
            entityId: "media_player.example_0602377b", state: "playing",
            attributes: [
                "friendly_name": .string("Living Room Sonos"),
                "media_title": .string("Calm Piano"),
                "media_artist": .string("Spotify"),
                "media_album_name": .string("Peaceful Mornings"),
                "media_duration": .double(234.0),
                "media_position": .double(107.0),
                "media_position_updated_at": .string(now),
                "volume_level": .double(0.35),
                "is_volume_muted": .bool(false),
                "shuffle": .bool(false),
                "repeat": .string("off"),
                "entity_picture": .string("/api/media_player_proxy/media_player.example_0602377b"),
            ],
            lastChanged: now, lastUpdated: now
        )

        // Mock appliance sensors
        demo["sensor.example_5e6551b9"] = HAEntity(
            entityId: "sensor.example_5e6551b9", state: "running",
            attributes: ["friendly_name": .string("Dishwasher")],
            lastChanged: now, lastUpdated: now
        )
        demo["sensor.example_eeb348c9"] = HAEntity(
            entityId: "sensor.example_eeb348c9", state: "idle",
            attributes: ["friendly_name": .string("Washing Machine")],
            lastChanged: now, lastUpdated: now
        )

        // Second Sonos speaker (idle)
        demo["media_player.example_47265f35"] = HAEntity(
            entityId: "media_player.example_47265f35", state: "idle",
            attributes: [
                "friendly_name": .string("Kitchen Sonos"),
                "volume_level": .double(0.25),
                "is_volume_muted": .bool(false),
            ],
            lastChanged: now, lastUpdated: now
        )

        // Weather entity for outdoor temperature on history charts
        demo["weather.forecast_home"] = HAEntity(
            entityId: "weather.forecast_home", state: "cloudy",
            attributes: [
                "friendly_name": .string("Home"),
                "temperature": .double(7.2),
                "humidity": .int(68),
            ],
            lastChanged: now, lastUpdated: now
        )

        // Temperature sensors for rooms
        let tempSensors: [(String, String, Double)] = [
            ("sensor.example_ff2fefe2", "Living Room Temperature", 20.5),
            ("sensor.example_f978f96a", "Kitchen Temperature", 19.8),
            ("sensor.example_45cc56c0", "Bedroom Temperature", 18.2),
            ("sensor.example_dcd47f6e", "Office Temperature", 21.1),
        ]
        for (id, name, temp) in tempSensors {
            demo[id] = HAEntity(
                entityId: id, state: String(format: "%.1f", temp),
                attributes: ["friendly_name": .string(name), "unit_of_measurement": .string("°C")],
                lastChanged: now, lastUpdated: now
            )
        }

        // Humidity sensors
        let humSensors: [(String, String, Double)] = [
            ("sensor.example_bbe570dc", "Living Room Humidity", 48.5),
            ("sensor.example_2d65cbd7", "Kitchen Humidity", 52.3),
            ("sensor.example_710cde8e", "Bedroom Humidity", 45.1),
            ("sensor.example_5a1468d5", "Office Humidity", 43.8),
        ]
        for (id, name, hum) in humSensors {
            demo[id] = HAEntity(
                entityId: id, state: String(format: "%.1f", hum),
                attributes: ["friendly_name": .string(name), "unit_of_measurement": .string("%")],
                lastChanged: now, lastUpdated: now
            )
        }

        // Mock scenes and scripts
        let mockScenes: [(String, String)] = [
            ("scene.example_00c12986", "Goodnight"),
            ("scene.example_5fb129fc", "Leaving House"),
            ("scene.example_8f4894e2", "Movie Time"),
            ("script.example_49259490", "Boost Heating"),
            ("script.example_15b49f30", "Kids Bedtime"),
        ]
        for (id, name) in mockScenes {
            demo[id] = HAEntity(
                entityId: id, state: "scening",
                attributes: ["friendly_name": .string(name)],
                lastChanged: now, lastUpdated: now
            )
        }

        entities = demo
        isConnected = false
        lastFetch = nil
        lastError = nil

        // Mock ZHA LQI data
        zhaLqi = [
            "light.example_d7ab5b9b": 210,
            "light.example_ff6f3185": 195,
            "light.example_3f2a461f": 180,
            "light.example_3cf6e630": 120,
            "light.example_ab6b8df0": 200,
            "binary_sensor.example_e1938001": 155,
            "binary_sensor.example_cadfe0f1": 90,
        ]
    }

    /// Restore a previously successful real snapshot for quiet offline display.
    func restoreLastKnownEntities(
        _ cachedEntities: [String: HAEntity],
        fetchedAt: Date?,
        manifest cachedManifest: HomeManifestDTO? = nil,
        sitrep cachedSitrep: HomeSitrepDTO? = nil
    ) {
        guard !isDemoMode else { return }
        entities = cachedEntities
        manifest = cachedManifest
        sitrep = cachedSitrep
        isConnected = false
        lastFetch = fetchedAt
        lastError = nil
    }

    /// Remove displayed state without changing the authenticated app session.
    func discardDisplayedState() {
        entities = [:]
        zhaLqi = [:]
        isConnected = false
        lastFetch = nil
        lastError = nil
        isDemoMode = false
        manifest = nil
        sitrep = nil
    }

    /// Reset client state (e.g. on logout or settings change).
    func reset() {
        stopPolling()
        entities = [:]
        isConnected = false
        lastFetch = nil
        lastError = nil
        backendConfigured = false
        isDemoMode = false
        manifest = nil
        sitrep = nil
        zhaLqi = [:]
        imageCache.removeAllObjects()
    }
}

// MARK: - Errors

enum HAClientError: LocalizedError {
    case notConfigured
    case unavailable
    case notFound
    case invalidRequest
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Home Assistant is not configured for this family."
        case .unavailable:
            return "Home Assistant is unavailable through HausKlar."
        case .notFound:
            return "The Home Assistant entity is no longer available."
        case .invalidRequest:
            return "The Home Assistant action contains unsupported data."
        case .invalidResponse:
            return "HausKlar received an unexpected Home Assistant response."
        }
    }
}
