import Foundation

/// Typed form of the relative navigation contract carried by local/push
/// notification payloads. Unknown views are rejected rather than silently
/// opening an unrelated authenticated screen.
enum HausKlarReminderRoute: Equatable, Sendable {
    case today
    case calendar(eventID: String?)
    case tasks(taskID: String?)
    case renewals(renewalID: String?)
    case library(loanID: String)
    case meals
    case routines
    case prepPacks
    case family
    case naps(napID: String?, childID: String?)

    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    init?(value: String) {
        guard value.utf8.count <= 4_096,
            value.unicodeScalars.allSatisfy(Self.isSafeScalar),
            let components = URLComponents(string: value),
            components.scheme == nil,
            components.host == nil,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.path == "/" || components.path.isEmpty,
            components.fragment == nil,
            let query = Self.validatedQuery(components.queryItems),
            let view = query["view"] ?? nil
        else {
            return nil
        }

        switch view {
        case "today":
            guard query.keys.allSatisfy({ $0 == "view" || $0 == "tomorrow" }),
                query["tomorrow"].flatMap({ $0 }).map({ $0 == "1" }) ?? true
            else { return nil }
            self = .today
        case "calendar":
            guard query.keys.allSatisfy({ $0 == "view" || $0 == "event" }),
                let eventID = Self.optionalIdentifier(query["event"])
            else { return nil }
            self = .calendar(eventID: eventID)
        case "lists":
            guard let section = query["section"] ?? nil else {
                guard query.keys.allSatisfy({ $0 == "view" || $0 == "task" }),
                    let taskID = Self.optionalIdentifier(query["task"])
                else { return nil }
                self = .tasks(taskID: taskID)
                return
            }
            switch section {
            case "tasks":
                guard query.keys.allSatisfy({ $0 == "view" || $0 == "section" || $0 == "task" }),
                    let taskID = Self.optionalIdentifier(query["task"])
                else { return nil }
                self = .tasks(taskID: taskID)
            case "renewals":
                if query.keys.contains("library") {
                    guard
                        query.keys.allSatisfy({
                            $0 == "view" || $0 == "section" || $0 == "library"
                        }),
                        let loanID = Self.optionalIdentifier(query["library"]),
                        let loanID
                    else { return nil }
                    self = .library(loanID: loanID)
                } else {
                    guard
                        query.keys.allSatisfy({
                            $0 == "view" || $0 == "section" || $0 == "renewal"
                        }),
                        let renewalID = Self.optionalIdentifier(query["renewal"])
                    else { return nil }
                    self = .renewals(renewalID: renewalID)
                }
            case "meals":
                guard Set(query.keys) == ["view", "section"] else { return nil }
                self = .meals
            case "routines":
                guard Set(query.keys) == ["view", "section"] else { return nil }
                self = .routines
            case "prep":
                guard Set(query.keys) == ["view", "section"] else { return nil }
                self = .prepPacks
            default:
                return nil
            }
        case "family":
            guard let section = query["section"] ?? nil else {
                guard Set(query.keys) == ["view"] else { return nil }
                self = .family
                return
            }
            switch section {
            case "naps":
                guard
                    query.keys.allSatisfy({
                        $0 == "view" || $0 == "section" || $0 == "nap" || $0 == "child"
                    }),
                    let napID = Self.optionalIdentifier(query["nap"]),
                    let childID = Self.optionalIdentifier(query["child"]),
                    (napID == nil) == (childID == nil)
                else { return nil }
                self = .naps(napID: napID, childID: childID)
            case "medicine":
                guard Set(query.keys) == ["view", "section"] else { return nil }
                self = .family
            default:
                return nil
            }
        case "finance":
            // Finance reminder detail routing remains web-only. Accept the
            // server's exact finite shape and preserve the existing Today
            // fallback without retaining its identifiers.
            guard
                query.keys.allSatisfy({
                    $0 == "view" || $0 == "section" || $0 == "action" || $0 == "scope"
                }),
                query["section"] ?? nil == "coach",
                let action = Self.optionalIdentifier(query["action"]),
                action != nil,
                let scope = Self.optionalIdentifier(query["scope"]),
                scope != nil
            else { return nil }
            self = .today
        case "documents":
            guard query.keys.allSatisfy({ $0 == "view" || $0 == "document" }),
                let documentID = Self.optionalIdentifier(query["document"]),
                documentID != nil
            else { return nil }
            self = .today
        default:
            return nil
        }
    }

    private static func validatedQuery(_ items: [URLQueryItem]?) -> [String: String?]? {
        var result: [String: String?] = [:]
        for item in items ?? [] {
            guard !item.name.isEmpty,
                item.name.utf8.count <= 32,
                item.name.unicodeScalars.allSatisfy(identifierCharacters.contains),
                result.index(forKey: item.name) == nil,
                item.value != nil
            else { return nil }
            result[item.name] = item.value
        }
        return result
    }

    private static func optionalIdentifier(_ wrapped: String??) -> String?? {
        guard let wrapped else { return .some(nil) }
        guard let value = wrapped,
            !value.isEmpty,
            value.utf8.count <= 160,
            value.unicodeScalars.allSatisfy(identifierCharacters.contains)
        else { return nil }
        return .some(value)
    }

    private static func isSafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar)
            && scalar.properties.generalCategory != .format
            && scalar.properties.generalCategory != .lineSeparator
            && scalar.properties.generalCategory != .paragraphSeparator
    }
}
