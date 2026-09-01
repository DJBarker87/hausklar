import SwiftUI
import UIKit

/// Centralised device-type-to-colour mapping used by the 2D floor plan,
/// 3D floor plan, device action sheet, and any other view that needs to
/// colour-code HA devices by type and state.
///
/// The logic mirrors the duplicated `deviceColor` / `deviceUIColor` functions
/// that previously existed in `FloorPlanView`, `FloorPlan3DView`, and
/// `DeviceActionSheet`.
enum DeviceColors {

    // MARK: - SwiftUI Color

    /// Returns `(Color, opacity)` for a given device type and its current HA entity.
    static func color(for type: String, entity: HAEntity?) -> (Color, Double) {
        let isOn = entity?.isOn ?? false

        switch type {
        case "light", "plug", "speaker":
            return (.hackerGreen, isOn ? 0.60 : 0.35)

        case "contact":
            return isOn ? (.hackerRed, 0.70) : (.hackerGreen, 0.35)

        case "motion":
            return isOn ? (.hackerOrange, 0.70) : (.hackerGrey, 0.30)

        case "trv":
            let hvacAction = entity?.hvacAction ?? "off"
            switch hvacAction {
            case "heating": return (.hackerOrange, 0.60)
            case "idle":    return (.hackerGreen, 0.60)
            default:        return (.hackerGrey, 0.25)
            }

        case "appliance":
            let state = entity?.state ?? "off"
            let isRunning = state != "off" && state != "unavailable" && state != "unknown"
            return isRunning ? (.hackerCyan, 0.70) : (.hackerGrey, 0.30)

        case "boiler":
            return isOn ? (.hackerOrange, 0.70) : (.hackerGrey, 0.50)

        case "temperature":
            return (.hackerGreen, 0.50)

        case "camera":
            return (.hackerGreen, 0.50)

        default:
            return (.hackerGreen, 0.35)
        }
    }

    // MARK: - UIKit UIColor

    /// Returns `(UIColor, opacity)` for a given device type and its current HA entity.
    /// Used by SceneKit (3D floor plan) and other UIKit contexts.
    /// Derives from `color(for:entity:)` to avoid duplicated logic.
    static func uiColor(for type: String, entity: HAEntity?) -> (UIColor, CGFloat) {
        let (swiftUIColor, opacity) = color(for: type, entity: entity)
        return (UIColor(swiftUIColor), CGFloat(opacity))
    }

    // MARK: - Accent Color (simplified, for action sheets / UI chrome)

    /// Returns a single accent `Color` for a device (no opacity). Used by `DeviceActionSheet`.
    static func accentColor(for type: String, entity: HAEntity?) -> Color {
        switch type {
        case "light", "plug":
            return entity?.isOn == true ? .hackerGreen : .hackerGrey
        case "trv":
            let hvac = entity?.hvacAction ?? "off"
            return hvac == "heating" ? .hackerOrange : hvac == "idle" ? .hackerGreen : .hackerGrey
        case "contact":
            return entity?.isOn == true ? .hackerRed : .hackerGreen
        case "speaker":
            return entity?.state == "playing" ? .hackerGreen : .hackerGrey
        case "appliance":
            let state = entity?.state ?? "off"
            return (state != "off" && state != "unavailable" && state != "unknown") ? .hackerCyan : .hackerGrey
        case "boiler":
            return entity?.isOn == true ? .hackerOrange : .hackerGrey
        case "motion":
            return entity?.isOn == true ? .hackerOrange : .hackerGrey
        case "temperature":
            return .hackerGreen
        case "camera":
            return .hackerGreen
        default:
            return .hackerGreen
        }
    }
}
