import Foundation

/// Redirect policy for requests carrying HausKlar bearer credentials.
///
/// Foundation may remove `Authorization` while following a redirect. HausKlar
/// deliberately restores it only for an exact HTTPS origin match. An
/// authenticated downgrade, host change, or port change is rejected instead
/// of being followed without credentials or risking credential disclosure.
enum AuthenticatedRedirectPolicy {
    static func redirectedRequest(
        original: URLRequest?,
        proposed: URLRequest
    ) -> URLRequest? {
        guard let original,
            sameHTTPSOrigin(original.url, proposed.url)
        else {
            return nil
        }
        var result = proposed
        if let authorization = original.value(forHTTPHeaderField: "Authorization") {
            guard authorization.lowercased().hasPrefix("bearer ") else { return nil }
            result.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return result
    }

    static func sameHTTPSOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs = canonicalHTTPSOrigin(lhs),
            let rhs = canonicalHTTPSOrigin(rhs)
        else { return false }
        return lhs == rhs
    }

    static func canonicalHTTPSOrigin(_ url: URL?) -> Origin? {
        guard let url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            components.fragment == nil
        else {
            return nil
        }
        // A percent-escaped host is needlessly ambiguous for an authenticated
        // redirect. Normal IDNA hosts arrive in canonical punycode form.
        guard let encodedHost = components.percentEncodedHost,
            !encodedHost.contains("%"),
            var host = components.host?.lowercased(),
            !host.isEmpty
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        let port = components.port ?? 443
        guard (1...65_535).contains(port) else { return nil }
        return Origin(host: host, port: port)
    }

    struct Origin: Equatable {
        let host: String
        let port: Int
    }
}

/// Foundation may invoke redirect callbacks concurrently. This base class has
/// no mutable state; stateful subclasses provide their own locking.
class AuthenticatedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            AuthenticatedRedirectPolicy.redirectedRequest(
                original: task.originalRequest,
                proposed: request
            )
        )
    }
}
