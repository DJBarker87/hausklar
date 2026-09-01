import SwiftUI
import UIKit

// MARK: - SwiftUI Color theme constants

extension Color {
    /// Hacker green — #39FF6E — the primary accent colour throughout the app.
    static let hackerGreen = Color(red: 0x39/255, green: 0xFF/255, blue: 0x6E/255)

    /// Red used for open doors / alerts — #FF4444 (rgb 1.0, 0.267, 0.267).
    static let hackerRed = Color(red: 1.0, green: 0.267, blue: 0.267)

    /// Orange used for heating / active states — #FF9500 (rgb 1.0, 0.584, 0).
    static let hackerOrange = Color(red: 1.0, green: 0.584, blue: 0)

    /// Cyan used for appliances — #00B4D8 (rgb 0, 0.706, 0.851).
    static let hackerCyan = Color(red: 0, green: 0.706, blue: 0.851)

    /// Grey used for off / inactive states — #808080 (WCAG AA compliant against dark backgrounds).
    static let hackerGrey = Color(white: 0x80/255.0)

    /// Amber used for motion glow / warnings — #FFB800 (rgb 1.0, 0.722, 0).
    static let hackerAmber = Color(red: 1.0, green: 0.722, blue: 0)

    /// Mesh signal: weak/red — same as HA-reported weak LQI (rgb 1.0, 0.231, 0.188).
    static let meshWeak = Color(red: 1.0, green: 0.231, blue: 0.188)

    /// External door color on floor plan (same as iOS system red #FF3B30).
    static let externalDoor = Color(red: 1.0, green: 0.231, blue: 0.188)
}

// MARK: - UIKit UIColor theme constants

extension UIColor {
    /// Hacker green — #39FF6E.
    static let hackerGreen = UIColor(red: 0x39/255, green: 0xFF/255, blue: 0x6E/255, alpha: 1)

    /// Red — #FF4444.
    static let hackerRed = UIColor(red: 1.0, green: 0.267, blue: 0.267, alpha: 1)

    /// Orange — #FF9500.
    static let hackerOrange = UIColor(red: 1.0, green: 0.584, blue: 0, alpha: 1)

    /// Cyan — #00B4D8.
    static let hackerCyan = UIColor(red: 0, green: 0.706, blue: 0.851, alpha: 1)

    /// Grey — #808080 (WCAG AA compliant against dark backgrounds).
    static let hackerGrey = UIColor(white: 0x80/255, alpha: 1)

    /// Amber — #FFB800.
    static let hackerAmber = UIColor(red: 1.0, green: 0.722, blue: 0, alpha: 1)
}
