import Foundation

enum ExternalAuthorizationProvider: Sendable {
    case intervals
    case strava
    case withings
    case trueLayer

    fileprivate var host: String {
        switch self {
        case .intervals: "intervals.icu"
        case .strava: "www.strava.com"
        case .withings: "account.withings.com"
        case .trueLayer: "auth.truelayer.com"
        }
    }

    fileprivate func allows(path: String) -> Bool {
        switch self {
        case .intervals, .strava:
            path == "/oauth/authorize"
        case .withings:
            path == "/oauth2_user/authorize2"
        case .trueLayer:
            path == "/" || path.hasPrefix("/session/")
        }
    }
}

/// Exact origins and path families that may be presented in an external web
/// authentication session. Server-returned strings are untrusted until they
/// cross this boundary.
enum ProviderAuthorizationURLPolicy {
    private static let maximumURLBytes = 8 * 1_024

    static func validatedURL(
        _ rawValue: String,
        provider: ExternalAuthorizationProvider
    ) -> URL? {
        guard rawValue.utf8.count <= maximumURLBytes,
            rawValue.unicodeScalars.allSatisfy(Self.isSafeScalar),
            let url = URL(string: rawValue),
            allows(url, provider: provider)
        else {
            return nil
        }
        return url
    }

    static func allows(_ url: URL, provider: ExternalAuthorizationProvider) -> Bool {
        guard url.absoluteString.utf8.count <= maximumURLBytes,
            url.absoluteString.unicodeScalars.allSatisfy(Self.isSafeScalar),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == provider.host,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.fragment == nil,
            components.percentEncodedPath == components.path,
            provider.allows(path: components.path),
            hasUniqueQueryNames(components.queryItems)
        else {
            return false
        }
        return true
    }

    private static func hasUniqueQueryNames(_ items: [URLQueryItem]?) -> Bool {
        var names: Set<String> = []
        for item in items ?? [] {
            guard !item.name.isEmpty,
                item.value != nil,
                names.insert(item.name).inserted
            else { return false }
        }
        return true
    }

    private static func isSafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        !CharacterSet.controlCharacters.contains(scalar)
            && scalar.properties.generalCategory != .format
            && scalar.properties.generalCategory != .lineSeparator
            && scalar.properties.generalCategory != .paragraphSeparator
    }
}

enum HausKlarAuthorizationCallback: Equatable, Sendable {
    enum Provider: Sendable {
        case intervals
        case strava
        case withings
        case finance

        fileprivate var route: (host: String, path: String, queryName: String) {
            switch self {
            case .intervals: ("fitness", "/intervals", "status")
            case .strava: ("fitness", "/strava", "status")
            case .withings: ("fitness", "/withings", "status")
            case .finance: ("finance-bank", "", "bank")
            }
        }
    }

    case connected
    case cancelled
    case failed

    init?(url: URL, provider: Provider) {
        let route = provider.route
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "hausklar",
            components.host == route.host,
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.path == route.path,
            components.percentEncodedPath == components.path,
            components.fragment == nil,
            let items = components.queryItems,
            items.count == 1,
            items[0].name == route.queryName,
            let value = items[0].value
        else {
            return nil
        }
        switch value {
        case "connected": self = .connected
        case "cancelled": self = .cancelled
        case "failed": self = .failed
        default: return nil
        }
    }
}
