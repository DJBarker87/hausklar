import CryptoKit
import Foundation

/// Keeps exactly one owner's last confirmed lock-screen preference. A missing,
/// malformed, or different-owner value is private by default. `lock` covers
/// both the cached payload and every post-initialization UserDefaults access.
final class NotificationPrivacyPolicyStore: @unchecked Sendable {
    static let shared = NotificationPrivacyPolicyStore()

    private struct Payload: Codable, Equatable {
        let ownerToken: String
        let privacyMode: Bool
    }

    private static let storageKey = "notificationPrivacyPolicy.v1"  // gitleaks:allow

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedPayload: Payload?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
            let payload = try? PropertyListDecoder().decode(Payload.self, from: data)
        {
            cachedPayload = payload
        } else {
            cachedPayload = nil
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    func privacyMode(for ownerIdentity: String?) -> Bool {
        guard let ownerIdentity else { return true }
        let token = Self.ownerToken(ownerIdentity)
        return lock.withLock {
            guard cachedPayload?.ownerToken == token else { return true }
            return cachedPayload?.privacyMode ?? true
        }
    }

    func update(privacyMode: Bool, for ownerIdentity: String?) {
        guard let ownerIdentity else {
            clear()
            return
        }
        let payload = Payload(
            ownerToken: Self.ownerToken(ownerIdentity),
            privacyMode: privacyMode
        )
        do {
            let data = try PropertyListEncoder().encode(payload)
            lock.withLock {
                defaults.set(data, forKey: Self.storageKey)
                cachedPayload = payload
            }
        } catch {
            // Encoding this fixed string/bool payload should never fail. If it
            // ever does, forgetting the opt-out restores the private default.
            clear()
        }
    }

    func clear() {
        lock.withLock {
            cachedPayload = nil
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    private static func ownerToken(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum NotificationPrivacyKind: Equatable {
    case reminder
    case test
    case summary
    case event
    case task
    case renewal
    case library
    case document
    case insight
    case vaccination
    case nap
    case security
    case anomaly
    case fitness

    static func reminderPreview(_ value: String) -> NotificationPrivacyKind {
        switch value.lowercased() {
        case "event": return .event
        case "task": return .task
        case "renewal": return .renewal
        case "library": return .library
        case "document": return .document
        case "insight": return .insight
        case "vaccination": return .vaccination
        default: return .reminder
        }
    }
}

struct NotificationDisplayContent: Equatable {
    let title: String
    let body: String
}

enum NotificationPrivacyPolicy {
    static func displayContent(
        kind: NotificationPrivacyKind,
        title: String,
        body: String,
        privacyMode: Bool
    ) -> NotificationDisplayContent {
        guard privacyMode else {
            return NotificationDisplayContent(title: title, body: body)
        }

        switch kind {
        case .security:
            return NotificationDisplayContent(
                title: "Security alert",
                body: "A security issue needs checking now."
            )
        case .anomaly:
            return NotificationDisplayContent(
                title: "Home alert",
                body: "Something at home needs checking."
            )
        case .summary:
            return NotificationDisplayContent(title: title, body: body)
        case .fitness:
            return NotificationDisplayContent(
                title: "Rest complete",
                body: "Your next set is ready."
            )
        case .nap:
            return NotificationDisplayContent(
                title: "Nap timer needs checking",
                body: "Open the active nap."
            )
        case .event:
            return NotificationDisplayContent(title: "Upcoming event", body: body)
        case .task:
            return NotificationDisplayContent(title: "Task due", body: body)
        case .renewal:
            return NotificationDisplayContent(title: "Renewal due", body: body)
        case .library:
            return NotificationDisplayContent(title: "Library book due", body: body)
        case .document:
            return NotificationDisplayContent(
                title: "Document ready to review",
                body: "A document has suggestions ready to check."
            )
        case .insight:
            return NotificationDisplayContent(
                title: "Family update",
                body: "HausKlar noticed something worth checking."
            )
        case .vaccination:
            return NotificationDisplayContent(
                title: "Vaccination reminder",
                body: "A vaccination is due soon."
            )
        case .reminder:
            return NotificationDisplayContent(
                title: "HausKlar reminder",
                body: "Something needs checking in HausKlar."
            )
        case .test:
            return NotificationDisplayContent(title: title, body: body)
        }
    }
}
