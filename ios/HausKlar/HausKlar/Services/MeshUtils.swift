import SwiftUI

/// Zigbee mesh signal utilities — ports meshUtils.ts to Swift.
struct MeshUtils {

    private static let zigbeeTypes: Set<String> = ["light", "plug", "appliance", "trv", "motion", "contact", "temperature"]
    private static let routerTypes: Set<String> = ["light", "plug", "appliance"]

    static func isZigbeeDevice(_ type: String) -> Bool {
        zigbeeTypes.contains(type)
    }

    static func isMeshRouter(_ type: String) -> Bool {
        routerTypes.contains(type)
    }

    /// Extract LQI from entity attributes, derived linkquality sensor, or ZHA LQI cache.
    static func getLqi(entityId: String, entities: [String: HAEntity], zhaLqi: [String: Int] = [:]) -> Int? {
        // Check attributes on the entity itself (Zigbee2MQTT style)
        if let entity = entities[entityId],
           let lq = entity.attributes["linkquality"] {
            switch lq {
            case .int(let v): return v
            case .double(let v): return Int(v)
            case .string(let s): return Int(s)
            default: break
            }
        }

        // Check for a separate linkquality sensor
        let name = entityId.components(separatedBy: ".").last ?? ""
        let lqEntityId = "sensor.\(name)_linkquality"
        if let lqEntity = entities[lqEntityId],
           lqEntity.state != "unknown" && lqEntity.state != "unavailable",
           let val = Int(lqEntity.state) {
            return val
        }

        // Check ZHA LQI cache (fetched from config-api /api/zha-lqi)
        if let lqi = zhaLqi[entityId] {
            return lqi
        }

        return nil
    }

    /// Map LQI (0–255) to signal color.
    static func lqiToColor(_ lqi: Int?) -> Color {
        guard let lqi else { return .hackerGrey }
        if lqi >= 171 { return .hackerGreen }
        if lqi >= 86 { return .hackerOrange }
        return .meshWeak
    }

    /// Human-readable signal label.
    static func signalLabel(_ lqi: Int?) -> String {
        guard let lqi else { return "NO DATA" }
        if lqi >= 171 { return "STRONG" }
        if lqi >= 86 { return "MEDIUM" }
        return "WEAK"
    }

    struct MeshDeviceInfo {
        let lqi: Int?
        let isRouter: Bool
        let color: Color
        let signalLabel: String
    }

    /// Build mesh info for a device.
    static func meshInfo(type: String, entityId: String, entities: [String: HAEntity], zhaLqi: [String: Int] = [:]) -> MeshDeviceInfo {
        let lqi = getLqi(entityId: entityId, entities: entities, zhaLqi: zhaLqi)
        return MeshDeviceInfo(
            lqi: lqi,
            isRouter: isMeshRouter(type),
            color: lqiToColor(lqi),
            signalLabel: signalLabel(lqi)
        )
    }
}
