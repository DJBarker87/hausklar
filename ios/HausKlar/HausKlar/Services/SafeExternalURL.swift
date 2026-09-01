import Foundation

/// Converts family-authored or server-returned strings into URLs that are safe
/// to hand to the operating system. This boundary is intentionally stricter
/// than `URL(string:)`: syntactically valid file, custom-scheme, credentialed,
/// or ambiguous-host URLs are not external web links.
enum SafeExternalURL {
    private static let maximumLength = 2_048
    private static let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    private static let dnsLabelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    )
    private static let mailboxCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~@"
    )
    private static let telephoneCharacters = CharacterSet(
        charactersIn: "+0123456789-()."
    )

    static func web(_ rawValue: String?) -> URL? {
        guard let value = prepared(rawValue),
            hasValidPercentEscapes(value),
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.port == nil || components.port == 443,
            components.host != nil,
            let rawHost = explicitlyEncodedHost(in: value),
            isUnambiguousHost(rawHost),
            let url = components.url,
            url.scheme?.lowercased() == "https"
        else {
            return nil
        }
        return url
    }

    /// Allows web links plus narrowly formed telephone and email destinations.
    /// Call this only where the interface explicitly labels the action as
    /// contacting somebody.
    static func contact(_ rawValue: String?) -> URL? {
        if let webURL = web(rawValue) {
            return webURL
        }
        guard let value = prepared(rawValue), hasValidPercentEscapes(value),
            let components = URLComponents(string: value),
            components.user == nil,
            components.password == nil,
            components.host == nil,
            components.port == nil,
            components.query == nil,
            components.fragment == nil
        else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "mailto":
            guard let decoded = components.percentEncodedPath.removingPercentEncoding,
                decoded.count <= 254,
                decoded.unicodeScalars.allSatisfy(mailboxCharacters.contains),
                isSingleMailbox(decoded)
            else {
                return nil
            }
        case "tel":
            guard let decoded = components.percentEncodedPath.removingPercentEncoding,
                !decoded.isEmpty,
                decoded.count <= 32,
                decoded.unicodeScalars.allSatisfy(telephoneCharacters.contains),
                decoded.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
            else {
                return nil
            }
        default:
            return nil
        }
        return components.url
    }

    private static func prepared(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.count <= maximumLength,
            value.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    && scalar.properties.generalCategory != .format
                    && scalar.properties.generalCategory != .lineSeparator
                    && scalar.properties.generalCategory != .paragraphSeparator
            })
        else {
            return nil
        }
        return value
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

    /// `URLComponents.host` presents an IDNA-decoded Unicode hostname on newer
    /// Foundation releases. Validate the spelling the caller actually supplied
    /// so canonical ASCII punycode is accepted while a raw Unicode or
    /// percent-escaped authority remains rejected as ambiguous.
    private static func explicitlyEncodedHost(in value: String) -> String? {
        guard let delimiter = value.range(of: "://"),
              value[..<delimiter.lowerBound].lowercased() == "https" else {
            return nil
        }
        let authorityStart = delimiter.upperBound
        let authorityEnd = value[authorityStart...].firstIndex {
            $0 == "/" || $0 == "?" || $0 == "#"
        } ?? value.endIndex
        let authority = value[authorityStart..<authorityEnd]
        guard !authority.isEmpty else { return nil }

        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]") else { return nil }
            let hostStart = authority.index(after: authority.startIndex)
            let suffixStart = authority.index(after: closingBracket)
            let suffix = authority[suffixStart...]
            guard suffix.isEmpty || (suffix.first == ":" && suffix.dropFirst().allSatisfy(\.isNumber))
            else { return nil }
            return String(authority[hostStart..<closingBracket])
        }

        if let colon = authority.lastIndex(of: ":") {
            let port = authority[authority.index(after: colon)...]
            if !port.isEmpty, port.allSatisfy(\.isNumber) {
                return String(authority[..<colon])
            }
        }
        return String(authority)
    }

    private static func isUnambiguousHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        guard host == host.trimmingCharacters(in: .whitespacesAndNewlines),
            !normalized.isEmpty,
            normalized.count <= 253,
            !normalized.hasPrefix("."),
            !normalized.hasSuffix("."),
            !normalized.contains(".."),
            !normalized.contains("%"),
            !normalized.contains("\\"),
            normalized.unicodeScalars.allSatisfy({ $0.isASCII })
        else {
            return false
        }

        // URLComponents removes IPv6 brackets. A literal address is
        // unambiguous and safe to open because HausKlar credentials are never
        // attached to these operating-system handoffs.
        if normalized.contains(":") {
            return normalized.unicodeScalars.allSatisfy {
                hexadecimal.contains($0) || $0 == ":" || $0 == "."
            }
        }

        return normalized.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty,
                label.count <= 63,
                label.first != "-",
                label.last != "-"
            else {
                return false
            }
            return label.unicodeScalars.allSatisfy(dnsLabelCharacters.contains)
        }
    }

    private static func isSingleMailbox(_ mailbox: String) -> Bool {
        guard !mailbox.contains(","), !mailbox.contains(";"), !mailbox.contains("/") else {
            return false
        }
        let parts = mailbox.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return isUnambiguousHost(String(parts[1]))
    }
}
