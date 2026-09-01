import Foundation

extension Locale {
    static var hausKlarSelected: Locale {
        switch UserDefaults.standard.string(forKey: "appLanguage") {
        case "en": Locale(identifier: "en")
        case "de": Locale(identifier: "de")
        default: .current
        }
    }
}

extension String {
    var localized: String {
        let languageCode = UserDefaults.standard.string(forKey: "appLanguage")
        guard languageCode == "en" || languageCode == "de",
              let resourcePath = Bundle.main.path(
                forResource: languageCode,
                ofType: "lproj"
              ),
              let languageBundle = Bundle(path: resourcePath) else {
            return Bundle.main.localizedString(
                forKey: self,
                value: self,
                table: nil
            )
        }
        return languageBundle.localizedString(
            forKey: self,
            value: self,
            table: nil
        )
    }
}
