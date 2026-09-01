import Foundation

/// The complete open-only URL contract accepted from widgets, notifications,
/// App Intents, the share extension, and the operating system. Parsing happens
/// before a route is retained so an unauthenticated launch cannot smuggle an
/// unbounded or structurally ambiguous URL into a later family session.
enum HausKlarDeepLink: Codable, Equatable, Sendable {
    case capture(text: String?)
    case today
    case calendar(eventID: String?)
    case medicine(childID: String?, medicineTypeID: String?)
    case naps(napID: String?, childID: String?)
    case dog
    case starChart(chartID: String?, childID: String?)
    case photos(assetID: String?)
    case fitnessImports
    case fitnessWithings

    private static let maximumURLBytes = 12 * 1_024
    private static let maximumTextCharacters = 2_000
    private static let maximumTextBytes = 8 * 1_024
    private static let maximumIdentifierBytes = 160
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )
    private static let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    init?(url: URL) {
        let rawValue = url.absoluteString
        guard rawValue.utf8.count <= Self.maximumURLBytes,
            Self.hasValidRawCharacters(rawValue),
            Self.hasValidPercentEscapes(rawValue),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "hausklar",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.fragment == nil,
            let host = components.host,
            host == host.lowercased(),
            host.unicodeScalars.allSatisfy({ $0.isASCII }),
            components.percentEncodedPath == components.path,
            let query = Self.validatedQuery(components.queryItems)
        else {
            return nil
        }

        switch (host, components.path) {
        case ("capture", ""):
            guard query.keys.allSatisfy({ $0 == "text" }),
                let text = Self.optionalText(query["text"])
            else { return nil }
            self = .capture(text: text)
        case ("today", ""):
            guard query.isEmpty else { return nil }
            self = .today
        case ("calendar", ""):
            guard query.keys.allSatisfy({ $0 == "event" }),
                let eventID = Self.optionalIdentifier(query["event"])
            else { return nil }
            self = .calendar(eventID: eventID)
        case ("medicine", ""):
            guard query.keys.allSatisfy({ $0 == "child_id" || $0 == "medicine_type_id" }),
                let childID = Self.optionalIdentifier(query["child_id"]),
                let medicineTypeID = Self.optionalIdentifier(query["medicine_type_id"])
            else { return nil }
            self = .medicine(childID: childID, medicineTypeID: medicineTypeID)
        case ("naps", ""):
            guard query.keys.allSatisfy({ $0 == "nap_id" || $0 == "child_id" }),
                let napID = Self.optionalIdentifier(query["nap_id"]),
                let childID = Self.optionalIdentifier(query["child_id"]),
                (napID == nil) == (childID == nil)
            else { return nil }
            self = .naps(napID: napID, childID: childID)
        case ("dog", ""):
            guard query.keys.allSatisfy({ $0 == "action" || $0 == "activity_id" }),
                let action = Self.optionalIdentifier(query["action"]),
                let activityID = Self.optionalIdentifier(query["activity_id"]),
                action.map(Self.validDogActions.contains) ?? true,
                activityID == nil || action != nil
            else { return nil }
            self = .dog
        case ("star-chart", ""):
            guard query.keys.allSatisfy({ $0 == "chart_id" || $0 == "child_id" }),
                let chartID = Self.optionalIdentifier(query["chart_id"]),
                let childID = Self.optionalIdentifier(query["child_id"]),
                (chartID == nil) == (childID == nil)
            else { return nil }
            self = .starChart(chartID: chartID, childID: childID)
        case ("photos", ""):
            guard query.keys.allSatisfy({ $0 == "asset_id" }),
                let assetID = Self.optionalIdentifier(query["asset_id"])
            else { return nil }
            self = .photos(assetID: assetID)
        case ("fitness", "/imports"):
            guard query.isEmpty else { return nil }
            self = .fitnessImports
        case ("fitness", "/withings"):
            guard query.keys.allSatisfy({ $0 == "status" }),
                let status = Self.optionalIdentifier(query["status"]),
                status.map(Self.validConnectionStatuses.contains) ?? true
            else { return nil }
            self = .fitnessWithings
        default:
            return nil
        }
    }

    private static let validDogActions: Set<String> = [
        "active_walk", "feed_breakfast", "walk", "feed_dinner", "overview",
    ]
    private static let validConnectionStatuses: Set<String> = [
        "connected", "cancelled", "failed",
    ]

    /// A missing key is valid for optional fields. A present field must have a
    /// nonempty, bounded value, so `?event` and `?event=` are not aliases for no
    /// event.
    private static func optionalIdentifier(_ wrapped: String??) -> String?? {
        guard let wrapped else { return .some(nil) }
        guard let value = wrapped,
            !value.isEmpty,
            value.utf8.count <= maximumIdentifierBytes,
            value.unicodeScalars.allSatisfy(identifierCharacters.contains)
        else {
            return nil
        }
        return .some(value)
    }

    private static func optionalText(_ wrapped: String??) -> String?? {
        guard let wrapped else { return .some(nil) }
        guard let value = wrapped,
            !value.isEmpty,
            value.count <= maximumTextCharacters,
            value.utf8.count <= maximumTextBytes,
            value.unicodeScalars.allSatisfy(Self.isSafeTextScalar)
        else {
            return nil
        }
        return .some(value)
    }

    private static func validatedQuery(_ items: [URLQueryItem]?) -> [String: String?]? {
        var result: [String: String?] = [:]
        for item in items ?? [] {
            guard !item.name.isEmpty,
                item.name.utf8.count <= 32,
                item.name.unicodeScalars.allSatisfy(identifierCharacters.contains),
                result.index(forKey: item.name) == nil
            else {
                return nil
            }
            result[item.name] = item.value
        }
        return result
    }

    private static func hasValidRawCharacters(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && scalar.properties.generalCategory != .format
                && scalar.properties.generalCategory != .lineSeparator
                && scalar.properties.generalCategory != .paragraphSeparator
        }
    }

    private static func isSafeTextScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar)
            && scalar.properties.generalCategory != .format
            && scalar.properties.generalCategory != .lineSeparator
            && scalar.properties.generalCategory != .paragraphSeparator
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "%" {
                guard index + 2 < scalars.count,
                    hexadecimal.contains(scalars[index + 1]),
                    hexadecimal.contains(scalars[index + 2])
                else {
                    return false
                }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }
}
