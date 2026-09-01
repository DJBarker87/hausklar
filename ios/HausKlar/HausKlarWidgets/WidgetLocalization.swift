import Foundation

extension String {
    var widgetLocalized: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}

enum WidgetCopy {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: key.widgetLocalized,
            locale: .current,
            arguments: arguments
        )
    }
}
