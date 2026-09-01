import Foundation

enum FinanceWebScope: String, Equatable, Sendable {
    case mine
    case household
}

/// Builds Finance browser links from the app's configured PWA address.
/// The iOS access token is never placed in the URL or shared with the browser.
struct FinanceWebRouter: Equatable, Sendable {
    let baseURL: URL

    init?(baseURL: URL) {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.queryItems == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              Self.isAllowed(scheme: scheme, host: host) else {
            return nil
        }

        var normalized = components
        normalized.path = "/"
        guard let normalizedURL = normalized.url else { return nil }
        self.baseURL = normalizedURL
    }

    static func configured(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FinanceWebRouter? {
        let configuredValue = environment["FINANCE_WEB_BASE_URL"]
            ?? bundle.object(forInfoDictionaryKey: "FinanceWebBaseURL") as? String
        guard let configuredValue,
              let url = URL(string: configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return FinanceWebRouter(baseURL: url)
    }

    func url(
        section: String,
        scope: FinanceWebScope,
        mode: String? = nil,
        recordQueryItems: [URLQueryItem] = []
    ) -> URL? {
        guard !section.isEmpty else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "view", value: "finance"),
            URLQueryItem(name: "section", value: section),
            URLQueryItem(name: "scope", value: scope.rawValue),
        ]
        if let mode {
            queryItems.append(URLQueryItem(name: "mode", value: mode))
        }
        queryItems.append(contentsOf: recordQueryItems)
        components?.queryItems = queryItems
        return components?.url
    }

    /// Accepts only an app-owned relative Finance link and keeps its full query.
    func url(relativeFinanceDeepLink deepLink: String) -> URL? {
        guard let source = URLComponents(string: deepLink),
              source.scheme == nil,
              source.host == nil,
              source.user == nil,
              source.password == nil,
              source.path == "/",
              source.queryItems?.filter({ $0.name == "view" }).map(\.value) == ["finance"] else {
            return nil
        }

        var destination = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        destination?.path = source.path
        destination?.queryItems = source.queryItems
        destination?.fragment = source.fragment
        return destination?.url
    }

    private static func isAllowed(scheme: String, host: String) -> Bool {
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}
