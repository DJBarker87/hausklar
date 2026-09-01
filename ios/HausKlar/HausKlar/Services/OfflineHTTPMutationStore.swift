import CryptoKit
import Foundation
import os

private enum OfflineHTTPMutationPolicy {
    static func allows(
        path: String,
        method: String,
        contentType: String?,
        hasInlineBody: Bool,
        hasBodyFile: Bool
    ) -> Bool {
        guard ["POST", "PUT", "PATCH", "DELETE"].contains(method) else { return false }
        let cleanPath = path.components(separatedBy: "?").first ?? path
        let ownedTypedQueues = ["/calendar", "/tasks", "/cycles", "/medicine", "/naps", "/documents"]
        if ownedTypedQueues.contains(where: { cleanPath == $0 || cleanPath.hasPrefix($0 + "/") }) {
            return false
        }
        let networkOnlyPrefixes = [
            "/auth", "/assistant", "/babysitter", "/fitness", "/library", "/home/actions", "/home/services",
            "/photos/search", "/reminders/test", "/reminders/push", "/sync",
            "/finance/analysis", "/finance/coach", "/finance/capture/interpret",
            "/finance/connections", "/finance/imports/preview", "/finance/assets/hl/import-preview",
            "/finance/assets/portfolio", "/finance/assets/watch-addresses", "/finance/assets/sources",
            "/finance/safe-to-spend", "/finance/patterns/scan", "/finance/shares/preview",
            "/finance/product-prices/rebuild",
        ]
        if networkOnlyPrefixes.contains(where: { cleanPath == $0 || cleanPath.hasPrefix($0 + "/") }) {
            return false
        }
        if cleanPath == "/capture/parse"
            || cleanPath == "/commitments/from-source"
            || cleanPath == "/commitments/free-windows/query"
            || (cleanPath.hasPrefix("/yearbook/") && cleanPath.hasSuffix("/refresh"))
            || (cleanPath.hasPrefix("/calendar/sources/") && cleanPath.hasSuffix("/sync"))
        {
            return false
        }
        if cleanPath == "/calendar/feed/rotate"
            || (cleanPath.hasPrefix("/finance/reports/") && cleanPath.hasSuffix("/refresh"))
            || cleanPath == "/finance/assets/hl/refresh-prices"
            || (cleanPath.hasPrefix("/finance/assets/sources/") && cleanPath.hasSuffix("/refresh"))
            || (cleanPath.hasPrefix("/finance/email-addresses/")
                && (cleanPath.hasSuffix("/send-test") || cleanPath.hasSuffix("/enrollments")))
        {
            return false
        }
        let lowerContentType = contentType?.lowercased()
        if lowerContentType?.contains("multipart/form-data") == true {
            guard hasBodyFile, !hasInlineBody else { return false }
            let resourcePath =
                cleanPath.count > 1 && cleanPath.hasSuffix("/")
                ? String(cleanPath.dropLast()) : cleanPath
            return resourcePath == "/artworks"
                || resourcePath == "/child-photos"
                || resourcePath == "/finance/purchases/evidence/upload"
                || (resourcePath.hasPrefix("/family/members/")
                    && resourcePath.hasSuffix("/avatar"))
        }
        guard !hasBodyFile else { return false }
        return method == "DELETE"
            || !hasInlineBody
            || lowerContentType?.contains("application/json") == true
    }
}

actor OfflineHTTPMutationStore {
    static let shared = OfflineHTTPMutationStore()

    /// Single public decision boundary for generic offline HTTP replay. The
    /// detailed endpoint policy remains file-private so callers cannot bypass
    /// the store's persistence validation.
    static func allows(
        path: String,
        method: String,
        contentType: String?,
        hasInlineBody: Bool,
        hasBodyFile: Bool
    ) -> Bool {
        OfflineHTTPMutationPolicy.allows(
            path: path,
            method: method,
            contentType: contentType,
            hasInlineBody: hasInlineBody,
            hasBodyFile: hasBodyFile
        )
    }

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "OfflineHTTPMutationStore"
    )

    private let directory: URL
    private let maxItems: Int
    private let maxEncodedBytes: Int
    private let maxRetries: Int
    private let now: () -> Date
    private let retryJitter: () -> Double
    private let fileManager: FileManager
    private let saveHook: () throws -> Void
    private var runtimeClaims: Set<String> = []

    init(
        directory: URL? = nil,
        maxItems: Int = 250,
        maxEncodedBytes: Int = 100 * 1_024 * 1_024,
        maxRetries: Int = 5,
        now: @escaping () -> Date = Date.init,
        retryJitter: @escaping () -> Double = { Double.random(in: 0.8...1.2) },
        fileManager: FileManager = .default,
        saveHook: @escaping () throws -> Void = {}
    ) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let configuredDirectory =
            directory
            ?? support.appendingPathComponent("HausKlarOfflineRequests", isDirectory: true)
        // A caller can supply a queue root that does not exist yet using
        // appendingPathComponent(_:), which produces a file-shaped URL. Make
        // the directory intent explicit before the lazy first write so the
        // containment check compares equivalent parent URLs both before and
        // after the root is created.
        self.directory = URL(
            fileURLWithPath: configuredDirectory.standardizedFileURL.path,
            isDirectory: true
        )
        self.maxItems = max(1, maxItems)
        self.maxEncodedBytes = max(1, maxEncodedBytes)
        self.maxRetries = max(1, maxRetries)
        self.now = now
        self.retryJitter = retryJitter
        self.fileManager = fileManager
        self.saveHook = saveHook
        // Directory creation is lazy so the first throwing queue operation can
        // report protection or filesystem failures to its caller.
    }

    func enqueue(_ mutation: QueuedHTTPMutation, bodyFile: URL? = nil) throws {
        var values = try load(identity: mutation.identity)
        guard !values.contains(where: { $0.id == mutation.id }) else { return }
        let fileBytes: Int
        if let bodyFile {
            let values = try bodyFile.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let size = values.fileSize
            else {
                throw OfflineHTTPMutationStoreError.missingBodyFile
            }
            fileBytes = size
        } else {
            fileBytes = mutation.body?.count ?? 0
        }
        var stored = mutation
        stored.encodedBytes = fileBytes
        let destination: URL?
        if bodyFile != nil {
            let filename = Self.bodyFilename(id: mutation.id)
            stored.bodyFileName = filename
            destination = try validatedIdentityDirectory(
                mutation.identity,
                createIfMissing: true
            )
            .appendingPathComponent(filename, isDirectory: false)
        } else {
            destination = nil
        }
        values.append(stored)
        values.sort { $0.createdAt < $1.createdAt }
        let metadataBytes = try JSONEncoder().encode(values).count
        let durableBodyBytes = values.reduce(0) {
            $0 + ($1.bodyFileName == nil ? 0 : $1.encodedBytes)
        }
        guard values.count <= maxItems,
            metadataBytes <= maxEncodedBytes,
            durableBodyBytes <= maxEncodedBytes - metadataBytes
        else {
            throw OfflineHTTPMutationStoreError.capacityExceeded
        }
        do {
            if let bodyFile, let destination {
                try copyBodyAtomically(from: bodyFile, to: destination)
            }
            try validate(stored, expectedIdentity: mutation.identity)
            try save(values, identity: mutation.identity)
        } catch {
            if let destination {
                removeBestEffort(
                    destination,
                    context: "failed enqueue rollback"
                )
            }
            throw error
        }
    }

    func claimNext(identity: String) throws -> QueuedHTTPMutation? {
        var values = try load(identity: identity)
        var changed = false
        for index in values.indices
        where
            values[index].status == .inFlight && !runtimeClaims.contains(values[index].id)
        {
            values[index].status = .pending
            changed = true
        }
        let instant = now()
        guard
            let index = values.indices.first(where: { index in
                let value = values[index]
                guard value.status == .pending || value.status == .retryable else { return false }
                return value.nextAttemptAt.map { $0 <= instant } ?? true
            })
        else {
            if changed { try save(values, identity: identity) }
            return nil
        }
        values[index].status = .inFlight
        values[index].lastAttemptAt = instant
        values[index].nextAttemptAt = nil
        runtimeClaims.insert(values[index].id)
        try save(values, identity: identity)
        return values[index]
    }

    func complete(id: String, identity: String) throws {
        var values = try load(identity: identity)
        let acknowledgedBody = values.first(where: { $0.id == id })?.bodyFileName
        values.removeAll { $0.id == id }
        // Durably acknowledge first. If this save fails, the referenced body is
        // still intact and replayable. Cleanup is deliberately second phase.
        try save(values, identity: identity)
        runtimeClaims.remove(id)
        if let acknowledgedBody {
            do {
                let ownedDirectory = try validatedIdentityDirectory(
                    identity,
                    createIfMissing: false
                )
                removeBestEffort(
                    ownedDirectory.appendingPathComponent(acknowledgedBody),
                    context: "acknowledged body cleanup"
                )
            } catch {
                Self.logger.error(
                    "Acknowledged body cleanup validation failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next queue load retries bounded file reconciliation."
                )
            }
        }
        do {
            try reconcileFiles(
                identity: identity,
                referencedBodies: Set(values.compactMap(\.bodyFileName))
            )
        } catch {
            // The acknowledgement above is already durable. Throwing here
            // would replay a committed operation; load() provides the named
            // bounded reconciliation pass for harmless orphaned files.
            Self.logger.error(
                "Post-acknowledgement queue reconciliation failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next queue load retries bounded file reconciliation."
            )
        }
    }

    func releaseForAuthentication(id: String, identity: String) throws {
        var values = try load(identity: identity)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].status = .pending
        values[index].nextAttemptAt = nil
        values[index].lastError = "Waiting for authentication before retrying."
        runtimeClaims.remove(id)
        try save(values, identity: identity)
    }

    func releaseAfterCancellation(id: String, identity: String) throws {
        var values = try load(identity: identity)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].status = .pending
        values[index].nextAttemptAt = nil
        runtimeClaims.remove(id)
        try save(values, identity: identity)
    }

    func markRetryable(
        id: String,
        identity: String,
        error: String,
        statusCode: Int?
    ) throws {
        var values = try load(identity: identity)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].retryCount += 1
        values[index].lastError = error
        values[index].lastStatusCode = statusCode
        if values[index].retryCount >= maxRetries {
            values[index].status = .permanent
            values[index].nextAttemptAt = nil
        } else {
            values[index].status = .retryable
            let exponent = Double(max(0, values[index].retryCount - 1))
            let delay =
                min(5 * pow(2, exponent), 15 * 60)
                * min(max(retryJitter(), 0.8), 1.2)
            values[index].nextAttemptAt = now().addingTimeInterval(delay)
        }
        runtimeClaims.remove(id)
        try save(values, identity: identity)
    }

    func markPermanent(
        id: String,
        identity: String,
        error: String,
        statusCode: Int?
    ) throws {
        var values = try load(identity: identity)
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        values[index].retryCount += 1
        values[index].status = .permanent
        values[index].nextAttemptAt = nil
        values[index].lastError = error
        values[index].lastStatusCode = statusCode
        runtimeClaims.remove(id)
        try save(values, identity: identity)
    }

    func count(identity: String) throws -> Int {
        try load(identity: identity).count
    }

    func summaries(identity: String) throws -> [OfflineHTTPMutationSummary] {
        try load(identity: identity).map {
            OfflineHTTPMutationSummary(
                id: $0.id,
                method: $0.method,
                path: $0.path,
                status: $0.status,
                retryCount: $0.retryCount,
                nextAttemptAt: $0.nextAttemptAt,
                lastError: $0.lastError,
                lastStatusCode: $0.lastStatusCode,
                encodedBytes: $0.encodedBytes
            )
        }
    }

    func bodyFileURL(for mutation: QueuedHTTPMutation) throws -> URL? {
        guard let filename = mutation.bodyFileName else { return nil }
        try validate(mutation, expectedIdentity: mutation.identity)
        let file = try validatedIdentityDirectory(
            mutation.identity,
            createIfMissing: false
        ).appendingPathComponent(filename)
        return file
    }

    func purge(identity: String) throws {
        let identityDirectory = try validatedIdentityDirectory(identity, createIfMissing: false)
        runtimeClaims.removeAll()
        if fileManager.fileExists(atPath: identityDirectory.path) {
            try fileManager.removeItem(at: identityDirectory)
        }
    }

    private func identityDirectory(_ identity: String) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    private func validatedIdentityDirectory(
        _ identity: String,
        createIfMissing: Bool
    ) throws -> URL {
        let root = directory.standardizedFileURL
        try validateOwnedDirectory(root, createIfMissing: createIfMissing)
        let candidate = identityDirectory(identity).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else {
            throw OfflineHTTPMutationStoreError.corruptStore
        }
        try validateOwnedDirectory(candidate, createIfMissing: createIfMissing)
        return candidate
    }

    private func validateOwnedDirectory(
        _ url: URL,
        createIfMissing: Bool
    ) throws {
        // No-follow probe: a missing path throws and means "not a symlink";
        // an existing symlink fails closed as corrupt persistent state.
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw OfflineHTTPMutationStoreError.corruptStore
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            guard isDirectory.boolValue,
                values.isDirectory == true,
                values.isSymbolicLink != true
            else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            return
        }
        guard createIfMissing else { return }
        do {
            try LocalFileProtection.prepareDirectory(url, fileManager: fileManager)
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
        } catch is OfflineHTTPMutationStoreError {
            throw OfflineHTTPMutationStoreError.corruptStore
        } catch {
            throw OfflineHTTPMutationStoreError.corruptStore
        }
    }

    private func fileURL(identity: String) -> URL {
        identityDirectory(identity).appendingPathComponent("queue.json", isDirectory: false)
    }

    private func load(identity: String) throws -> [QueuedHTTPMutation] {
        let ownedDirectory = try validatedIdentityDirectory(identity, createIfMissing: false)
        let file = ownedDirectory.appendingPathComponent("queue.json", isDirectory: false)
        if !fileManager.fileExists(atPath: file.path) {
            let legacy = legacyFileURL(identity: identity)
            guard fileManager.fileExists(atPath: legacy.path) else {
                try reconcileFiles(identity: identity, referencedBodies: [])
                return []
            }
            let migrated = try JSONDecoder().decode(
                [QueuedHTTPMutation].self,
                from: readBoundedMetadata(at: legacy)
            )
            guard migrated.allSatisfy({ $0.identity == identity }) else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            try save(migrated, identity: identity)
            try fileManager.removeItem(at: legacy)
        }
        var values = try JSONDecoder().decode(
            [QueuedHTTPMutation].self,
            from: readBoundedMetadata(at: file)
        )
        let migratedMultipart = try migrateInlineMultipartBodies(
            &values,
            identity: identity
        )
        for value in values {
            try validate(value, expectedIdentity: identity)
        }
        if migratedMultipart {
            try save(values, identity: identity)
        }
        try reconcileFiles(
            identity: identity,
            referencedBodies: Set(values.compactMap(\.bodyFileName))
        )
        return values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Queue metadata is attacker/corruption-facing persistent input. Stat it
    /// before allocating so a symlink, special file, or oversized corrupt JSON
    /// cannot bypass the same total-byte ceiling used when the queue is saved.
    private func readBoundedMetadata(at url: URL) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw OfflineHTTPMutationStoreError.corruptStore
        }
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            let byteCount = values.fileSize,
            byteCount >= 0,
            byteCount <= maxEncodedBytes
        else {
            throw OfflineHTTPMutationStoreError.corruptStore
        }
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw OfflineHTTPMutationStoreError.corruptStore
        }
    }

    /// Older releases embedded multipart bodies as base64 inside queue.json.
    /// Migrate them body-first, then atomically replace metadata, so interruption
    /// always leaves either the original inline body or the new protected file.
    private func migrateInlineMultipartBodies(
        _ values: inout [QueuedHTTPMutation],
        identity: String
    ) throws -> Bool {
        var changed = false
        for index in values.indices {
            guard values[index].bodyFileName == nil,
                values[index].contentType?.lowercased().contains("multipart/form-data") == true,
                let body = values[index].body
            else { continue }
            let filename = Self.bodyFilename(id: values[index].id)
            let parent = try validatedIdentityDirectory(identity, createIfMissing: true)
            let destination = parent.appendingPathComponent(filename)
            try body.write(to: destination, options: [.atomic, .completeFileProtection])
            try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
            values[index].body = nil
            values[index].bodyFileName = filename
            values[index].encodedBytes = body.count
            changed = true
        }
        return changed
    }

    private func legacyFileURL(identity: String) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    private func save(_ values: [QueuedHTTPMutation], identity: String) throws {
        try saveHook()
        let identityDirectory = try validatedIdentityDirectory(identity, createIfMissing: true)
        let file = identityDirectory.appendingPathComponent("queue.json", isDirectory: false)
        if values.isEmpty {
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.removeItem(at: file)
            }
            return
        }
        let data = try JSONEncoder().encode(values)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try LocalFileProtection.protectItem(at: file, fileManager: fileManager)
    }

    private func copyBodyAtomically(from source: URL, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try validateOwnedDirectory(parent, createIfMissing: true)
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer {
            removeBestEffort(staging, context: "body staging cleanup")
        }
        try fileManager.copyItem(at: source, to: staging)
        try LocalFileProtection.protectItem(at: staging, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
    }

    private func validate(
        _ mutation: QueuedHTTPMutation,
        expectedIdentity: String
    ) throws {
        guard !mutation.id.isEmpty,
            !mutation.identity.isEmpty,
            mutation.identity == expectedIdentity,
            ["POST", "PUT", "PATCH", "DELETE"].contains(mutation.method),
            Self.isValidRelativeMutationPath(mutation.path),
            mutation.encodedBytes >= 0,
            mutation.retryCount >= 0,
            Self.isValidContentType(mutation.contentType),
            OfflineHTTPMutationPolicy.allows(
                path: mutation.path,
                method: mutation.method,
                contentType: mutation.contentType,
                hasInlineBody: mutation.body != nil,
                hasBodyFile: mutation.bodyFileName != nil
            )
        else {
            throw OfflineHTTPMutationStoreError.corruptStore
        }
        if let filename = mutation.bodyFileName {
            guard mutation.body == nil,
                filename == Self.bodyFilename(id: mutation.id),
                filename == URL(fileURLWithPath: filename).lastPathComponent
            else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            let parent = try validatedIdentityDirectory(
                expectedIdentity,
                createIfMissing: false
            )
            let file = parent.appendingPathComponent(filename).standardizedFileURL
            guard file.deletingLastPathComponent() == parent,
                fileManager.fileExists(atPath: file.path)
            else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            let resource: URLResourceValues
            do {
                resource = try file.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            guard resource.isRegularFile == true,
                resource.isSymbolicLink != true,
                resource.fileSize == mutation.encodedBytes,
                mutation.contentType?.lowercased().contains("multipart/form-data") == true
            else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
        } else {
            guard mutation.encodedBytes == (mutation.body?.count ?? 0),
                mutation.contentType?.lowercased().contains("multipart/form-data") != true
            else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
        }
    }

    private func reconcileFiles(identity: String, referencedBodies: Set<String>) throws {
        let identityDirectory = try validatedIdentityDirectory(identity, createIfMissing: false)
        guard fileManager.fileExists(atPath: identityDirectory.path) else { return }
        var enumerationFailed = false
        guard
            let files = fileManager.enumerator(
                at: identityDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                }
            )
        else { throw OfflineHTTPMutationStoreError.corruptStore }
        var removed = 0
        let maximumRemovals = 64
        let maximumEntries = maxItems + 512
        var inspected = 0
        var retainedEntry = false
        while let file = files.nextObject() as? URL {
            inspected += 1
            guard inspected <= maximumEntries else {
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            let name = file.lastPathComponent
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true {
                if name.hasPrefix(".staging-") || name.hasSuffix(".body") {
                    // Never unlink or traverse a path that may be provider-owned.
                    retainedEntry = true
                    continue
                }
                throw OfflineHTTPMutationStoreError.corruptStore
            }
            if name == "queue.json" || referencedBodies.contains(name) {
                guard values.isRegularFile == true else {
                    throw OfflineHTTPMutationStoreError.corruptStore
                }
                retainedEntry = true
                continue
            }
            if name.hasPrefix(".staging-") || name.hasSuffix(".body") {
                guard values.isRegularFile == true else {
                    retainedEntry = true
                    continue
                }
                if removed < maximumRemovals {
                    try fileManager.removeItem(at: file)
                    removed += 1
                } else {
                    retainedEntry = true
                }
                continue
            }
            throw OfflineHTTPMutationStoreError.corruptStore
        }
        guard !enumerationFailed else { throw OfflineHTTPMutationStoreError.corruptStore }
        if !retainedEntry {
            try fileManager.removeItem(at: identityDirectory)
        }
    }

    private static func isValidRelativeMutationPath(_ path: String) -> Bool {
        // Validation is intentionally a boolean probe: malformed persistent
        // input maps to `corruptStore` in validate(_:expectedIdentity:).
        (try? APIRequestPath.validateStoredValue(path)) != nil
    }

    private func removeBestEffort(_ url: URL, context: String) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.error(
                "Offline queue \(context, privacy: .public) failed: \(error.localizedDescription, privacy: .public). Reconciliation: the next queue load retries bounded file reconciliation."
            )
        }
    }

    private static func isValidContentType(_ contentType: String?) -> Bool {
        guard let contentType else { return true }
        guard !contentType.contains("\r"), !contentType.contains("\n") else { return false }
        let lower = contentType.lowercased()
        return lower == "application/json"
            || lower.hasPrefix("multipart/form-data; boundary=hausklar-")
    }

    private static func bodyFilename(id: String) -> String {
        let digest = SHA256.hash(data: Data(id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".body"
    }
}
