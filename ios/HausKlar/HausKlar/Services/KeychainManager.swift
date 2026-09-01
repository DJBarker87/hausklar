import Foundation
import Security
import os

/// Errors that can occur during Keychain operations.
enum KeychainError: LocalizedError {
    case loadFailed(OSStatus)
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case encodingFailed
    case invalidSessionEnvelope

    var errorDescription: String? {
        switch self {
        case .loadFailed(let status):
            return "Keychain read failed with status \(status)."
        case .saveFailed(let status):
            return "Keychain save failed with status \(status)."
        case .deleteFailed(let status):
            return "Keychain delete failed with status \(status)."
        case .encodingFailed:
            return "Failed to encode value for Keychain."
        case .invalidSessionEnvelope:
            return "The stored session is incomplete or invalid."
        }
    }
}

/// A durable device identity is required for mutation provenance. This error is
/// deliberately separate from authentication: read-only/auth bootstrap work can
/// remain available, but callers must never substitute a temporary identifier.
enum ClientIdentityError: LocalizedError, Equatable {
    case malformedStoredIdentifier
    case persistenceNotVerified
    case unavailable

    var errorDescription: String? {
        switch self {
        case .malformedStoredIdentifier:
            return "This device's stored sync identity is invalid. Restart HausKlar and try again."
        case .persistenceNotVerified:
            return "HausKlar could not verify this device's secure sync identity. Please try again."
        case .unavailable:
            return "Changes are unavailable because this device's secure sync identity could not be opened. Unlock the device and try again."
        }
    }
}

/// One atomic, versioned Keychain value for all authentication state. Keeping
/// the profile and credential pair together prevents a partial write from ever
/// combining one account's local identity with another account's tokens.
struct StoredSessionEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let identity: String
    let accessToken: String
    let refreshToken: String
    let userJSON: String

    init(
        version: Int = currentVersion,
        identity: String,
        accessToken: String,
        refreshToken: String,
        userJSON: String
    ) {
        self.version = version
        self.identity = identity
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userJSON = userJSON
    }
}

/// Provides static methods for saving, loading, and deleting secrets from the iOS Keychain.
/// Also generates and persists a unique client ID on first launch for sync tracking.
struct KeychainManager {

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "Keychain"
    )

    // MARK: - Well-Known Keys

    enum Keys {
        static let sessionEnvelope = "org.example.hausklar.session.v1"
        // Legacy keys are read only by the one-way migration below. New code
        // must use `sessionEnvelope` so the credential set remains atomic.
        static let accessToken = "org.example.hausklar.accessToken"
        static let refreshToken = "org.example.hausklar.refreshToken"
        static let clientId = "org.example.hausklar.clientId"
        static let currentUser = "currentUser"
    }

    // MARK: - Private

    private static let service = "org.example.hausklar"
    private static let legacyHomeAssistantCredentialKeys = [
        "org.example.hausklar.haToken",
        "org.example.hausklar.haURL",
    ]

    typealias LoadItem = (String) throws -> String?
    typealias SaveItem = (String, String) throws -> Bool
    typealias DeleteItem = (String) throws -> Bool

    // MARK: - Public Methods

    /// Saves a string value to the Keychain under the given key.
    /// If a value already exists for the key, it is overwritten.
    @discardableResult
    static func save(key: String, value: String) throws -> Bool {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let protectedAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: key),
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            protectedAttributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.saveFailed(updateStatus)
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: key),
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        return true
    }

    /// Loads a string value from the Keychain for the given key.
    /// Returns nil only when no value exists; Keychain availability and data
    /// failures remain distinguishable at this security boundary.
    static func load(key: String) throws -> String? {
        try loadSecurely(key: key)
    }

    /// Throwing Keychain read used at security boundaries where an unavailable
    /// item must remain distinguishable from a genuinely absent item.
    private static func loadSecurely(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        return value
    }

    /// Deletes a value from the Keychain for the given key.
    @discardableResult
    static func delete(key: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
        return true
    }

    /// Saves the complete session with one atomic `SecItemUpdate`/`SecItemAdd`.
    /// Legacy items are removed only after the new value has been encoded,
    /// written, read back, and verified.
    static func saveSessionEnvelope(
        _ envelope: StoredSessionEnvelope,
        loadItem: LoadItem = { try loadSecurely(key: $0) },
        saveItem: SaveItem = { try save(key: $0, value: $1) },
        deleteItem: DeleteItem = { try delete(key: $0) }
    ) throws {
        try validate(envelope)
        let data = try JSONEncoder().encode(envelope)
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        _ = try saveItem(Keys.sessionEnvelope, value)
        guard let storedValue = try loadItem(Keys.sessionEnvelope),
              let storedData = storedValue.data(using: .utf8) else {
            throw KeychainError.invalidSessionEnvelope
        }
        let verified = try decodeSessionEnvelope(from: storedData)
        guard verified == envelope else { throw KeychainError.invalidSessionEnvelope }
        for key in legacySessionKeys {
            _ = try deleteItem(key)
        }
    }

    /// Loads the authoritative envelope, migrating an all-or-nothing legacy
    /// credential/profile triplet on first access. A failed migration returns an
    /// error rather than authenticating from independently stored values.
    static func loadSessionEnvelope(
        loadItem: LoadItem = { try loadSecurely(key: $0) },
        saveItem: SaveItem = { try save(key: $0, value: $1) },
        deleteItem: DeleteItem = { try delete(key: $0) }
    ) throws -> StoredSessionEnvelope? {
        if let value = try loadItem(Keys.sessionEnvelope) {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.invalidSessionEnvelope
            }
            let envelope = try decodeSessionEnvelope(from: data)
            try validate(envelope)
            // A prior migration may have been interrupted during cleanup. The
            // verified envelope remains authoritative, but authentication is not
            // published until all independently readable legacy residue is gone.
            for key in legacySessionKeys {
                _ = try deleteItem(key)
            }
            return envelope
        }

        let values = try legacySessionKeys.map(loadItem)
        guard values.contains(where: { $0 != nil }) else { return nil }
        guard let accessToken = values[0],
              let refreshToken = values[1],
              let userJSON = values[2],
              let identity = legacyIdentity(from: userJSON) else {
            throw KeychainError.invalidSessionEnvelope
        }
        let envelope = StoredSessionEnvelope(
            identity: identity,
            accessToken: accessToken,
            refreshToken: refreshToken,
            userJSON: userJSON
        )
        try saveSessionEnvelope(
            envelope,
            loadItem: loadItem,
            saveItem: saveItem,
            deleteItem: deleteItem
        )
        return envelope
    }

    /// Deletes the authoritative session first, then removes any legacy residue.
    /// Callers can fail closed if deleting the authoritative value fails.
    static func deleteSessionEnvelope(
        deleteItem: DeleteItem = { try delete(key: $0) }
    ) throws {
        _ = try deleteItem(Keys.sessionEnvelope)
        for key in legacySessionKeys {
            _ = try deleteItem(key)
        }
    }

    static func sessionAccessToken(
        loadItem: LoadItem = { try loadSecurely(key: $0) }
    ) -> String? {
        // Widget processes are strictly read-only consumers. They neither
        // migrate nor clean up credentials, avoiding cross-process rotation or
        // Keychain writes from an extension timeline refresh.
        do {
            guard let value = try loadItem(Keys.sessionEnvelope),
                  let data = value.data(using: .utf8) else { return nil }
            let envelope = try decodeSessionEnvelope(from: data)
            try validate(envelope)
            return envelope.accessToken
        } catch {
            // Extensions must fail closed. A future timeline refresh retries the
            // authoritative Keychain read after the device becomes available.
            logger.error(
                "Widget session read failed closed: \(error.localizedDescription, privacy: .public). Reconciliation: the next timeline refresh retries the authoritative envelope read."
            )
            return nil
        }
    }

    private static let legacySessionKeys = [
        Keys.accessToken,
        Keys.refreshToken,
        Keys.currentUser,
    ]

    private static func validate(_ envelope: StoredSessionEnvelope) throws {
        guard envelope.version == StoredSessionEnvelope.currentVersion,
              !envelope.identity.isEmpty,
              !envelope.accessToken.isEmpty,
              !envelope.refreshToken.isEmpty,
              !envelope.userJSON.isEmpty,
              legacyIdentity(from: envelope.userJSON) == envelope.identity else {
            throw KeychainError.invalidSessionEnvelope
        }
    }

    private static func decodeSessionEnvelope(from data: Data) throws -> StoredSessionEnvelope {
        do {
            return try JSONDecoder().decode(StoredSessionEnvelope.self, from: data)
        } catch {
            throw KeychainError.invalidSessionEnvelope
        }
    }

    private static func legacyIdentity(from userJSON: String) -> String? {
        // This is a schema probe used only to validate untrusted legacy JSON;
        // malformed input intentionally maps to an invalid envelope below.
        guard let data = userJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userID = object["id"] as? String,
              !userID.isEmpty else { return nil }
        let familyID = (object["familyId"] as? String)
            ?? (object["family_id"] as? String)
            ?? "no-family"
        return "\(familyID):\(userID)"
    }

    /// Remove credentials stored by builds that connected directly to Home Assistant.
    /// This is intentionally best-effort cleanup of inert, non-session legacy
    /// items; unlike session migration, a failure cannot publish torn auth state.
    static func deleteLegacyHomeAssistantCredentials(
        deleteItem: (String) throws -> Bool = { try delete(key: $0) }
    ) {
        for key in legacyHomeAssistantCredentialKeys {
            do {
                _ = try deleteItem(key)
            } catch {
                // These credentials are inert in current builds. Continue so a
                // failure for one item does not prevent cleanup of the other;
                // every invocation retries both named legacy keys.
                logger.error(
                    "Legacy Home Assistant credential cleanup failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next cleanup invocation retries both legacy credential keys."
                )
            }
        }
    }

    /// Tighten items created by older builds without changing their values.
    static func migrateStoredItemProtection(
        updateItem: (String, CFString) -> OSStatus = updateAccessibility
    ) {
        for key in [
            Keys.sessionEnvelope,
            Keys.accessToken,
            Keys.refreshToken,
            Keys.currentUser,
            Keys.clientId,
        ] {
            let status = updateItem(key, accessibility(for: key))
            guard status != errSecSuccess, status != errSecItemNotFound else { continue }
            logger.error(
                "Keychain protection migration failed with status \(status, privacy: .public). Reconciliation: the next API client initialization retries protection migration."
            )
        }
    }

    static func accessibility(for key: String) -> CFString {
        if key == Keys.clientId {
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    private static func updateAccessibility(key: String, value: CFString) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: value,
        ]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    // MARK: - Client ID

    /// Returns only a verified, durable UUID. A new value is not usable until
    /// its Keychain write succeeds and an independent read returns the same ID.
    static func getOrCreateClientId(
        loadItem: LoadItem = { try loadSecurely(key: $0) },
        saveItem: SaveItem = { try save(key: $0, value: $1) },
        generate: () -> UUID = UUID.init
    ) throws -> String {
        if let existing = try loadItem(Keys.clientId) {
            guard UUID(uuidString: existing) != nil else {
                throw ClientIdentityError.malformedStoredIdentifier
            }
            return existing
        }

        let newId = generate().uuidString
        guard try saveItem(Keys.clientId, newId),
              let persisted = try loadItem(Keys.clientId),
              persisted == newId,
              UUID(uuidString: persisted) != nil else {
            throw ClientIdentityError.persistenceNotVerified
        }
        return newId
    }
}
