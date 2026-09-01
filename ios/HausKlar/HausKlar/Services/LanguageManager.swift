import Foundation
import SwiftUI

@MainActor
final class LanguageManager: ObservableObject {

    enum Language: String, CaseIterable, Identifiable {
        case system = "system"
        case english = "en"
        case german = "de"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .english: return "English"
            case .german: return "Deutsch"
            }
        }
    }

    @AppStorage("appLanguage") var selectedLanguage: Language = .system

    var locale: Locale {
        switch selectedLanguage {
        case .system: return .current
        case .english: return Locale(identifier: "en")
        case .german: return Locale(identifier: "de")
        }
    }
}
