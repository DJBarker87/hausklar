import Foundation
import os

/// Errors surfaced by the App Intents network layer.
enum IntentAPIError: LocalizedError {
    case notAuthenticated
    case server(String)
    case transport
    case queued

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please open HausKlar and sign in first, then try again."
        case .server(let message):
            return message
        case .transport:
            return "HausKlar couldn't reach the family server. Please try again."
        case .queued:
            return "Saved offline. HausKlar will sync it when you're connected."
        }
    }
}

/// App Intents run in the app process and use the same authenticated client as
/// the visible app. This preserves one refresh-token rotation and session-
/// generation contract instead of creating a second network stack.
enum IntentAPIClient {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.example.hausklar",
        category: "IntentAPIClient"
    )

    /// True when a complete, owner-scoped credential pair is available.
    static var isSignedIn: Bool {
        guard let identity = GlanceStore.activeIdentity else { return false }
        do {
            return try KeychainManager.loadSessionEnvelope()?.identity == identity
        } catch {
            logger.error(
                "Failed to inspect the persisted session for an App Intent: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func get<Response: Decodable>(
        _ path: APIRequestPath,
        queryItems: [URLQueryItem]? = nil,
        as: Response.Type = Response.self
    ) async throws -> Response {
        try prepareSessionIfNeeded()
        do {
            return try await APIClient.shared.get(path, queryItems: queryItems)
        } catch {
            throw map(error)
        }
    }

    /// POSTs an encodable body and decodes the response.
    @discardableResult
    static func post<Body: Encodable, Response: Decodable>(
        _ path: APIRequestPath,
        body: Body,
        as: Response.Type = Response.self
    ) async throws -> Response {
        try prepareSessionIfNeeded()
        do {
            return try await APIClient.shared.post(path, body: body)
        } catch {
            throw map(error)
        }
    }

    private static func prepareSessionIfNeeded() throws {
        guard APIClient.shared.currentSessionSnapshot() == nil else { return }
        guard let identity = GlanceStore.activeIdentity,
              let envelope = try KeychainManager.loadSessionEnvelope(),
              envelope.identity == identity else {
            throw IntentAPIError.notAuthenticated
        }
        APIClient.shared.installSession(
            identity: identity,
            accessToken: envelope.accessToken,
            refreshToken: envelope.refreshToken,
            persistTokenRotation: true
        )
    }

    private static func map(_ error: Error) -> IntentAPIError {
        guard let apiError = error as? APIError else { return .transport }
        switch apiError {
        case .unauthorized, .forbidden, .tokenRefreshFailed:
            return .notAuthenticated
        case .serverError(_, let message):
            return .server(message ?? "HausKlar couldn't complete that just now.")
        case .offlineQueued:
            return .queued
        case .offlineQueueFull:
            return .server("Offline storage is full. Open HausKlar and sync before trying again.")
        case .decodingError:
            return .server("HausKlar returned an unexpected response.")
        case .conflict:
            return .server("That changed elsewhere. Open HausKlar and review it first.")
        case .notFound:
            return .server("That family item is no longer available.")
        case .invalidURL, .networkError:
            return .transport
        }
    }
}

extension Notification.Name {
    static let ambientIntentRouteReady = Notification.Name("ambientIntentRouteReady")
}

/// Owner-scoped iOS 17 handoff used by open-only App Intents. The intent asks
/// iOS to open HausKlar; the app then consumes exactly one pending destination.
enum AmbientIntentRouteStore {
    private struct Payload: Codable {
        let ownerIdentity: String
        let route: HausKlarDeepLink
    }

    static let key = "ambient.pendingRoute"
    /// Serializes the compound UserDefaults read/remove transaction as well as
    /// competing save/clear mutations in this process. UserDefaults does not
    /// provide a cross-process compare-and-remove primitive; HausKlar's open-
    /// only App Intents intentionally execute in the containing app process.
    /// Moving this store into an extension would require file-level locking or
    /// another cross-process transaction mechanism.
    private static let processAccessLock = NSLock()
    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: GlanceStore.appGroupId)
    }

    static func save(_ url: URL) throws {
        guard let ownerIdentity = GlanceStore.activeIdentity else {
            throw IntentAPIError.notAuthenticated
        }
        guard let defaults else {
            throw IntentAPIError.server("HausKlar couldn't open that just now.")
        }
        guard let route = HausKlarDeepLink(url: url) else {
            throw IntentAPIError.server("HausKlar couldn't open that just now.")
        }
        try save(route, ownerIdentity: ownerIdentity, defaults: defaults)
        NotificationCenter.default.post(name: .ambientIntentRouteReady, object: nil)
    }

    static func take() -> HausKlarDeepLink? {
        guard let defaults else { return nil }
        guard let activeIdentity = GlanceStore.activeIdentity else {
            clear(defaults: defaults)
            return nil
        }
        return take(activeIdentity: activeIdentity, defaults: defaults)
    }

    static func clear() {
        guard let defaults else { return }
        clear(defaults: defaults)
    }

    static func save(
        _ route: HausKlarDeepLink,
        ownerIdentity: String,
        defaults: UserDefaults
    ) throws {
        guard !ownerIdentity.isEmpty, ownerIdentity.utf8.count <= 320 else {
            throw IntentAPIError.server("HausKlar couldn't open that just now.")
        }
        let payload = Payload(ownerIdentity: ownerIdentity, route: route)
        let data = try JSONEncoder().encode(payload)
        processAccessLock.withLock {
            defaults.set(data, forKey: key)
        }
    }

    static func take(
        activeIdentity: String,
        defaults: UserDefaults
    ) -> HausKlarDeepLink? {
        // Claim the pending bytes while holding the same lock as save/clear.
        // Decoding happens after the claim so malformed data cannot lengthen
        // the critical section and no second thread can consume the same route.
        let data = processAccessLock.withLock {
            let data = defaults.data(forKey: key)
            defaults.removeObject(forKey: key)
            return data
        }
        guard let data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        guard payload.ownerIdentity == activeIdentity else { return nil }
        return payload.route
    }

    static func clear(defaults: UserDefaults) {
        processAccessLock.withLock {
            defaults.removeObject(forKey: key)
        }
    }
}
