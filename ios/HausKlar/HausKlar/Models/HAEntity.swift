import Foundation

/// Represents a single Home Assistant entity state.
/// Built from the sanitized snapshot returned by the authenticated HausKlar API.
struct HAEntity: Codable, Identifiable, Sendable, Equatable {
    let entityId: String
    let state: String
    let attributes: [String: JSONValue]
    let lastChanged: String
    let lastUpdated: String

    var id: String { entityId }

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case state
        case attributes
        case lastChanged = "last_changed"
        case lastUpdated = "last_updated"
    }

    // MARK: - Convenience Accessors

    /// The friendly name from attributes, or the entity ID as fallback.
    var friendlyName: String {
        attributes["friendly_name"]?.stringValue ?? entityId
    }

    /// The domain portion of the entity ID (e.g. "light" from "light.example_ff6f3185").
    var domain: String {
        String(entityId.prefix(while: { $0 != "." }))
    }

    /// Whether the entity is in an "on" state.
    var isOn: Bool {
        state == "on"
    }

    /// Current temperature for climate entities.
    var currentTemperature: Double? {
        attributes["current_temperature"]?.doubleValue
    }

    /// Target temperature for climate entities.
    var targetTemperature: Double? {
        attributes["temperature"]?.doubleValue
    }

    /// HVAC action for climate entities (e.g. "heating", "idle").
    var hvacAction: String? {
        attributes["hvac_action"]?.stringValue
    }

    /// Available HVAC modes for climate entities (e.g. ["off", "heat", "auto"]).
    var hvacModes: [String] {
        if case .array(let values) = attributes["hvac_modes"] {
            return values.compactMap { $0.stringValue }
        }
        return []
    }

    /// Available preset modes for climate entities (e.g. ["boost", "Schedule"]).
    var presetModes: [String] {
        if case .array(let values) = attributes["preset_modes"] {
            return values.compactMap { $0.stringValue }
        }
        return []
    }

    /// Current preset mode for climate entities.
    var presetMode: String? {
        attributes["preset_mode"]?.stringValue
    }

    /// Minimum temperature for climate entities.
    var minTemp: Double? {
        attributes["min_temp"]?.doubleValue
    }

    /// Maximum temperature for climate entities.
    var maxTemp: Double? {
        attributes["max_temp"]?.doubleValue
    }

    /// Brightness for light entities (0-255).
    var brightness: Int? {
        attributes["brightness"]?.intValue
    }

    /// Media title for media_player entities.
    var mediaTitle: String? {
        attributes["media_title"]?.stringValue
    }

    /// Media artist for media_player entities.
    var mediaArtist: String? {
        attributes["media_artist"]?.stringValue
    }

    /// Media album name for media_player entities.
    var mediaAlbum: String? {
        attributes["media_album_name"]?.stringValue
    }

    /// Media duration in seconds for media_player entities.
    var mediaDuration: Double? {
        attributes["media_duration"]?.doubleValue
    }

    /// Media position in seconds for media_player entities.
    var mediaPosition: Double? {
        attributes["media_position"]?.doubleValue
    }

    /// ISO timestamp of when media_position was last updated.
    var mediaPositionUpdatedAt: String? {
        attributes["media_position_updated_at"]?.stringValue
    }

    /// Volume level (0.0–1.0) for media_player entities.
    var volumeLevel: Double? {
        attributes["volume_level"]?.doubleValue
    }

    /// Whether the media player is muted.
    var isVolumeMuted: Bool {
        attributes["is_volume_muted"]?.boolValue ?? false
    }

    /// Whether shuffle is enabled.
    var shuffleEnabled: Bool {
        attributes["shuffle"]?.boolValue ?? false
    }

    /// Repeat mode ("off", "all", "one").
    var repeatMode: String {
        attributes["repeat"]?.stringValue ?? "off"
    }

    /// Entity picture URL path (e.g. for album art).
    var entityPicture: String? {
        attributes["entity_picture"]?.stringValue
    }

    /// Options list for select entities (e.g. camera event selects).
    var selectOptions: [String] {
        if case .array(let values) = attributes["options"] {
            return values.compactMap { $0.stringValue }
        }
        return []
    }

    /// Recording URL for camera event entities.
    var recordingUrl: String? {
        attributes["recordingUrl"]?.stringValue
    }

    /// Battery level for battery-powered devices.
    var batteryLevel: Int? {
        attributes["battery_level"]?.intValue
    }

    /// Current source for media_player entities (e.g. "TV", "Spotify").
    var source: String? {
        attributes["source"]?.stringValue
    }

    /// Operation mode for water_heater entities (e.g. "eco", "on", "off").
    var operationMode: String? {
        attributes["operation_mode"]?.stringValue
    }

    /// Available operation modes for water_heater entities.
    var operationList: [String] {
        if case .array(let values) = attributes["operation_list"] {
            return values.compactMap { $0.stringValue }
        }
        return []
    }

    /// Group members for media_player entities (Sonos grouping).
    var groupMembers: [String] {
        if case .array(let values) = attributes["group_members"] {
            return values.compactMap { $0.stringValue }
        }
        return []
    }
}
