import UIKit
import UniformTypeIdentifiers

/// A single boundary for short-lived secrets copied out of HausKlar. Ordinary
/// public text, such as the family inbox address, deliberately does not use it.
enum SensitiveClipboard {
    static let defaultLifetime: TimeInterval = 120

    struct Payload {
        let items: [[String: Any]]
        let options: [UIPasteboard.OptionsKey: Any]
        let expirationDate: Date
    }

    @discardableResult
    static func copy(
        _ value: String,
        expiresAt sourceExpiration: Date? = nil,
        maximumLifetime: TimeInterval = defaultLifetime,
        now: Date = Date(),
        pasteboard: UIPasteboard = .general
    ) -> Bool {
        guard
            let payload = payload(
                value,
                expiresAt: sourceExpiration,
                maximumLifetime: maximumLifetime,
                now: now
            )
        else {
            return false
        }
        pasteboard.setItems(payload.items, options: payload.options)
        return true
    }

    static func payload(
        _ value: String,
        expiresAt sourceExpiration: Date?,
        maximumLifetime: TimeInterval,
        now: Date
    ) -> Payload? {
        guard !value.isEmpty,
            value.utf8.count <= 4_096,
            maximumLifetime > 0
        else {
            return nil
        }

        let lifetimeExpiration = now.addingTimeInterval(maximumLifetime)
        let expiration = sourceExpiration.map { min($0, lifetimeExpiration) } ?? lifetimeExpiration
        guard expiration > now else { return nil }

        return Payload(
            items: [[UTType.utf8PlainText.identifier: value]],
            options: [
                .expirationDate: expiration,
                .localOnly: true,
            ],
            expirationDate: expiration
        )
    }
}
