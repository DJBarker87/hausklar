import Foundation
import CryptoKit

enum LocalFileProtection {
    static let sensitive = FileProtectionType.complete

    static func prepareDirectory(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: sensitive]
        )
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fileManager.setAttributes(
            [.protectionKey: sensitive],
            ofItemAtPath: directory.path
        )
    }

    static func protectItem(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fileManager.setAttributes(
            [.protectionKey: sensitive],
            ofItemAtPath: url.path
        )
    }

    static func protectDirectoryRecursively(
        _ directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try prepareDirectory(directory, fileManager: fileManager)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else { return }
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try protectItem(at: child, fileManager: fileManager)
        }
    }

    static func protectSQLiteStore(
        at storeURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = storeURL.deletingLastPathComponent()
        try prepareDirectory(directory, fileManager: fileManager)
        let storeName = storeURL.lastPathComponent
        let ownedNames: Set<String> = [
            storeName,
            "\(storeName)-wal",
            "\(storeName)-shm",
            "\(storeName)-journal",
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in false }
        ) else { return }
        while let file = enumerator.nextObject() as? URL {
            guard file.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
                  ownedNames.contains(file.lastPathComponent) else { continue }
            let values = try file.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try protectItem(at: file, fileManager: fileManager)
        }
    }
}

actor FileCache {
    static let shared = FileCache()

    private struct DiskIndex: Codable {
        let version: Int
        var entries: [DiskEntry]
    }

    private struct DiskEntry: Codable {
        let key: String
        let filename: String
        let byteCount: Int
        let modifiedAt: Date
    }

    private final class MemoryEntry {
        let data: Data
        let modifiedAt: Date

        init(data: Data, modifiedAt: Date) {
            self.data = data
            self.modifiedAt = modifiedAt
        }
    }

    private let cacheDir: URL
    private let ttl: TimeInterval
    private let staleTTL: TimeInterval
    private let maxDiskBytes: Int
    private let maxDiskEntries: Int
    private let pruneEveryWrites: Int
    private let memory = NSCache<NSString, MemoryEntry>()
    private var diskCacheAvailable: Bool
    private var writesSinceLastPrune = 0
    private var diskEntries: [String: DiskEntry] = [:]
    private var diskBytes = 0

    /// Includes both memory-only entries and every key restored from the durable
    /// index. Targeted invalidation therefore works immediately after relaunch;
    /// it never depends on first reading each one-way hashed payload filename.
    private var keyIndex: Set<String> = []

    private static let diskIndexFilename = ".hausklar-cache-index-v1.json"
    private static let maximumDiskIndexBytes = 8 * 1_024 * 1_024
    private static let maximumDiskIndexEntries = 4_096

    init(
        cacheDir: URL? = nil,
        ttl: TimeInterval = 300,
        staleTTL: TimeInterval = 365 * 86_400,
        maxDiskBytes: Int = 250 * 1_024 * 1_024,
        maxDiskEntries: Int = 1_000,
        pruneEveryWrites: Int = 32
    ) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDir = cacheDir ?? caches.appendingPathComponent("APICache", isDirectory: true)
        self.ttl = ttl
        self.staleTTL = staleTTL
        self.maxDiskBytes = max(1, maxDiskBytes)
        self.maxDiskEntries = min(max(1, maxDiskEntries), Self.maximumDiskIndexEntries)
        self.pruneEveryWrites = max(1, pruneEveryWrites)
        self.diskCacheAvailable = false
        memory.countLimit = 100
        memory.totalCostLimit = 10 * 1_024 * 1_024
        do {
            try LocalFileProtection.prepareDirectory(self.cacheDir)
            let restored = try Self.restoreDiskIndex(
                at: self.cacheDir,
                staleTTL: staleTTL,
                maxBytes: self.maxDiskBytes,
                maxEntries: self.maxDiskEntries,
                fileManager: .default
            )
            self.diskEntries = restored.entries
            self.diskBytes = restored.totalBytes
            self.keyIndex = Set(restored.entries.keys)
            for entry in restored.entries.values {
                try LocalFileProtection.protectItem(
                    at: self.cacheDir.appendingPathComponent(entry.filename)
                )
            }
            if !restored.entries.isEmpty {
                try LocalFileProtection.protectItem(
                    at: self.cacheDir.appendingPathComponent(Self.diskIndexFilename)
                )
            }
            self.diskCacheAvailable = true
        } catch {
            // An absent index alongside payload files, a corrupt index, or an
            // index/payload mismatch is not recoverable safely: hashed files can
            // no longer be invalidated by resource or identity. Fail closed.
            do {
                if FileManager.default.fileExists(atPath: self.cacheDir.path) {
                    try FileManager.default.removeItem(at: self.cacheDir)
                }
                guard !FileManager.default.fileExists(atPath: self.cacheDir.path) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try LocalFileProtection.prepareDirectory(self.cacheDir)
                self.diskCacheAvailable = true
            } catch {
                self.diskCacheAvailable = false
            }
        }
    }

    func cacheKey(for url: String) -> String {
        let hash = SHA256.hash(data: Data(url.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    func get(_ url: String) -> (data: Data, isStale: Bool)? {
        get(url, maximumBytes: nil)
    }

    /// Applies a caller-specific read ceiling before disk bytes are materialized.
    /// A valid entry above the caller's policy remains cached for other callers;
    /// a payload whose on-disk size no longer matches its durable index is evicted.
    func get(_ url: String, maximumBytes: Int) -> (data: Data, isStale: Bool)? {
        guard maximumBytes > 0 else { return nil }
        return get(url, maximumBytes: Optional(maximumBytes))
    }

    private func get(
        _ url: String,
        maximumBytes: Int?
    ) -> (data: Data, isStale: Bool)? {
        let memoryKey = url as NSString
        if let entry = memory.object(forKey: memoryKey) {
            if let maximumBytes, entry.data.count > maximumBytes { return nil }
            return cachedValue(data: entry.data, modifiedAt: entry.modifiedAt, url: url)
        }

        guard diskCacheAvailable else { return nil }
        guard let entry = diskEntries[url] else { return nil }
        let file = cacheDir.appendingPathComponent(entry.filename)
        // Disk reads are fail-closed validation probes. Any inspection/read
        // failure evicts the durable index entry and reconciles the cache root.
        let values = try? file.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              values?.fileSize == entry.byteCount else {
            evictDiskEntryOrReset(for: url)
            return nil
        }
        if let maximumBytes, entry.byteCount > maximumBytes { return nil }
        guard let data = try? Self.readExactFile(
            at: file,
            expectedByteCount: entry.byteCount
        ) else {
            evictDiskEntryOrReset(for: url)
            return nil
        }
        memory.setObject(
            MemoryEntry(data: data, modifiedAt: entry.modifiedAt),
            forKey: memoryKey,
            cost: data.count
        )
        return cachedValue(data: data, modifiedAt: entry.modifiedAt, url: url)
    }

    func set(_ url: String, data: Data) {
        setMemory(url, data: data)
        guard diskCacheAvailable else { return }
        guard data.count <= maxDiskBytes else {
            // Do not spend time writing an entry that quota enforcement would
            // immediately remove. Any older disk value must also be removed so
            // a relaunch cannot resurrect stale data behind the memory value.
            evictDiskEntryOrReset(for: url)
            return
        }
        let file = cacheDir.appendingPathComponent(cacheKey(for: url))
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            try LocalFileProtection.protectItem(at: file)
            let modifiedAt = (try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
                as? Date) ?? Date()
            if let prior = diskEntries[url] {
                diskBytes -= prior.byteCount
            }
            let entry = DiskEntry(
                key: url,
                filename: cacheKey(for: url),
                byteCount: data.count,
                modifiedAt: modifiedAt
            )
            diskEntries[url] = entry
            diskBytes += data.count
            writesSinceLastPrune += 1
            if diskBytes > maxDiskBytes || diskEntries.count > maxDiskEntries
                || writesSinceLastPrune >= pruneEveryWrites {
                try pruneDiskCache(now: Date())
                writesSinceLastPrune = 0
            }
            try persistIndex()
        } catch {
            resetDiskCacheAfterFailure()
        }
    }

    /// Makes a successful response immediately reusable without putting file I/O
    /// on the caller's render-critical path. The durable write follows separately.
    func setMemory(_ url: String, data: Data) {
        let now = Date()
        memory.setObject(MemoryEntry(data: data, modifiedAt: now), forKey: url as NSString, cost: data.count)
        keyIndex.insert(url)
    }

    func clear() {
        memory.removeAllObjects()
        keyIndex.removeAll()
        writesSinceLastPrune = 0
        do {
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                try FileManager.default.removeItem(at: cacheDir)
            }
            guard !FileManager.default.fileExists(atPath: cacheDir.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try LocalFileProtection.prepareDirectory(cacheDir)
            diskEntries.removeAll()
            diskBytes = 0
            diskCacheAvailable = true
        } catch {
            diskEntries.removeAll()
            diskBytes = 0
            diskCacheAvailable = false
        }
    }

    /// Fail-closed identity-boundary purge. Unlike routine `clear()`, every
    /// filesystem error is surfaced so a different account cannot activate
    /// while an earlier account's API payloads may still exist on disk.
    func securePurge(fileManager: FileManager = .default) throws {
        memory.removeAllObjects()
        keyIndex.removeAll()
        diskEntries.removeAll()
        diskBytes = 0
        writesSinceLastPrune = 0
        if fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.removeItem(at: cacheDir)
        }
        guard !fileManager.fileExists(atPath: cacheDir.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try LocalFileProtection.prepareDirectory(cacheDir, fileManager: fileManager)
            diskCacheAvailable = true
        } catch {
            diskCacheAvailable = false
            throw error
        }
    }

    /// Removes entries whose key matches the predicate, including entries first
    /// written by an earlier process launch.
    func remove(where predicate: (String) -> Bool) {
        let removedKeys = keyIndex.filter(predicate)
        do {
            for key in removedKeys {
                memory.removeObject(forKey: key as NSString)
                try removeDiskEntry(for: key)
            }
            keyIndex.subtract(removedKeys)
            if !removedKeys.isEmpty {
                try persistIndex()
            }
        } catch {
            keyIndex.subtract(removedKeys)
            resetDiskCacheAfterFailure()
        }
    }

    func updateJSON(
        where predicate: (String) -> Bool,
        transform: (Any) -> Any?
    ) {
        // JSON parsing/encoding is deliberately optional cache transformation;
        // an invalid response remains untouched and is never durable state.
        for key in keyIndex.filter(predicate) {
            guard let cached = get(key),
                  let value = try? JSONSerialization.jsonObject(with: cached.data),
                  let updated = transform(value),
                  JSONSerialization.isValidJSONObject(updated),
                  let data = try? JSONSerialization.data(withJSONObject: updated) else { continue }
            set(key, data: data)
        }
    }

    func jsonRecordData(id: String) -> Data? {
        // Actor boundaries expose immutable bytes rather than Foundation's
        // non-Sendable `[String: Any]` object graph. Optional cache parsing or
        // re-encoding failure closes to “record unavailable”.
        for key in keyIndex {
            guard let cached = get(key),
                  let value = try? JSONSerialization.jsonObject(with: cached.data) else { continue }
            if let record = Self.findRecord(id: id, in: value),
               JSONSerialization.isValidJSONObject(record),
               let data = try? JSONSerialization.data(withJSONObject: record) {
                return data
            }
        }
        return nil
    }

    private static func findRecord(id: String, in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if object["id"] as? String == id { return object }
            for child in object.values {
                if let record = findRecord(id: id, in: child) { return record }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let record = findRecord(id: id, in: child) { return record }
            }
        }
        return nil
    }

    private func cachedValue(
        data: Data,
        modifiedAt: Date,
        url: String
    ) -> (data: Data, isStale: Bool)? {
        let age = Date().timeIntervalSince(modifiedAt)
        if age < ttl { return (data, false) }
        if age < staleTTL { return (data, true) }
        memory.removeObject(forKey: url as NSString)
        keyIndex.remove(url)
        evictDiskEntryOrReset(for: url)
        return nil
    }

    private func removeDiskEntry(for key: String) throws {
        guard let entry = diskEntries.removeValue(forKey: key) else { return }
        diskBytes = max(0, diskBytes - entry.byteCount)
        if diskCacheAvailable {
            try FileManager.default.removeItem(
                at: cacheDir.appendingPathComponent(entry.filename)
            )
        }
    }

    private func evictDiskEntryOrReset(for key: String) {
        do {
            try removeDiskEntry(for: key)
            try persistIndex()
        } catch {
            // Reset is the named reconciliation path for an index/payload
            // mismatch or failed eviction; no orphan is left advertised.
            resetDiskCacheAfterFailure()
        }
    }

    /// Uses the in-memory durable metadata and only sorts when a periodic expiry
    /// pass or an actual quota breach requires it. Normal reads and writes do not
    /// scan the cache directory.
    private func pruneDiskCache(now: Date) throws {
        let expired = diskEntries.values.filter {
            now.timeIntervalSince($0.modifiedAt) >= staleTTL
        }
        for entry in expired {
            memory.removeObject(forKey: entry.key as NSString)
            keyIndex.remove(entry.key)
            try removeDiskEntry(for: entry.key)
        }

        guard diskEntries.count > maxDiskEntries || diskBytes > maxDiskBytes else {
            return
        }
        var oldestFirst = diskEntries.values.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.filename < $1.filename }
            return $0.modifiedAt < $1.modifiedAt
        }
        while diskEntries.count > maxDiskEntries || diskBytes > maxDiskBytes {
            guard !oldestFirst.isEmpty else { break }
            let oldest = oldestFirst.removeFirst()
            memory.removeObject(forKey: oldest.key as NSString)
            keyIndex.remove(oldest.key)
            try removeDiskEntry(for: oldest.key)
        }
    }

    private var diskIndexURL: URL {
        cacheDir.appendingPathComponent(Self.diskIndexFilename, isDirectory: false)
    }

    private func persistIndex() throws {
        guard diskCacheAvailable else { return }
        if diskEntries.isEmpty {
            if FileManager.default.fileExists(atPath: diskIndexURL.path) {
                try FileManager.default.removeItem(at: diskIndexURL)
            }
            return
        }
        let index = DiskIndex(
            version: 1,
            entries: diskEntries.values.sorted { $0.key < $1.key }
        )
        let data = try JSONEncoder().encode(index)
        guard data.count <= Self.maximumDiskIndexBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: diskIndexURL, options: [.atomic, .completeFileProtection])
        try LocalFileProtection.protectItem(at: diskIndexURL)
    }

    private func persistIndexOrReset() {
        do {
            try persistIndex()
        } catch {
            resetDiskCacheAfterFailure()
        }
    }

    private func resetDiskCacheAfterFailure() {
        diskEntries.removeAll()
        diskBytes = 0
        // Memory entries can safely continue serving the current process, but
        // none is advertised as durably indexed until a later successful set.
        do {
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                try FileManager.default.removeItem(at: cacheDir)
            }
            guard !FileManager.default.fileExists(atPath: cacheDir.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try LocalFileProtection.prepareDirectory(cacheDir)
            diskCacheAvailable = true
        } catch {
            diskCacheAvailable = false
        }
    }

    private static func restoreDiskIndex(
        at directory: URL,
        staleTTL: TimeInterval,
        maxBytes: Int,
        maxEntries: Int,
        fileManager: FileManager = .default
    ) throws -> (entries: [String: DiskEntry], totalBytes: Int) {
        let indexURL = directory.appendingPathComponent(diskIndexFilename)
        guard fileManager.fileExists(atPath: indexURL.path) else {
            guard try directoryIsEmpty(directory, fileManager: fileManager) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return ([:], 0)
        }

        let indexValues = try indexURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard indexValues.isRegularFile == true,
              indexValues.isSymbolicLink != true,
              let indexByteCount = indexValues.fileSize,
              indexByteCount > 0,
              indexByteCount <= maximumDiskIndexBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let index = try JSONDecoder().decode(
            DiskIndex.self,
            from: readExactFile(at: indexURL, expectedByteCount: indexByteCount)
        )
        guard index.version == 1,
              index.entries.count <= maximumDiskIndexEntries else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let now = Date()
        var restored: [String: DiskEntry] = [:]
        var totalBytes = 0
        var indexChanged = false
        var expectedFilenames: Set<String> = [diskIndexFilename]
        for entry in index.entries {
            guard restored[entry.key] == nil,
                  entry.filename == hashedFilename(for: entry.key),
                  entry.byteCount >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let file = directory.appendingPathComponent(entry.filename)
            let values = try file.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == entry.byteCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            expectedFilenames.insert(entry.filename)
            if now.timeIntervalSince(entry.modifiedAt) >= staleTTL {
                try fileManager.removeItem(at: file)
                indexChanged = true
                continue
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(entry.byteCount)
            guard !overflow else { throw CocoaError(.fileReadCorruptFile) }
            restored[entry.key] = entry
            totalBytes = newTotal
        }

        var oldestFirst = restored.values.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.filename < $1.filename }
            return $0.modifiedAt < $1.modifiedAt
        }
        while restored.count > maxEntries || totalBytes > maxBytes {
            guard !oldestFirst.isEmpty else { break }
            let oldest = oldestFirst.removeFirst()
            try fileManager.removeItem(
                at: directory.appendingPathComponent(oldest.filename)
            )
            restored.removeValue(forKey: oldest.key)
            totalBytes -= oldest.byteCount
            indexChanged = true
        }

        try validateDirectoryEntries(
            in: directory,
            expectedFilenames: expectedFilenames,
            fileManager: fileManager
        )

        if restored.isEmpty {
            try fileManager.removeItem(at: indexURL)
        } else if indexChanged || restored.count != index.entries.count {
            let rewritten = DiskIndex(
                version: 1,
                entries: restored.values.sorted { $0.key < $1.key }
            )
            let data = try JSONEncoder().encode(rewritten)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
            try LocalFileProtection.protectItem(at: indexURL, fileManager: fileManager)
        }
        return (restored, totalBytes)
    }

    private static func directoryIsEmpty(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> Bool {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw CocoaError(.fileReadUnknown) }
        let first = enumerator.nextObject()
        if let enumerationError { throw enumerationError }
        return first == nil
    }

    private static func validateDirectoryEntries(
        in directory: URL,
        expectedFilenames: Set<String>,
        fileManager: FileManager
    ) throws {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else { throw CocoaError(.fileReadUnknown) }
        let root = directory.standardizedFileURL
        while let child = enumerator.nextObject() as? URL {
            let candidate = child.standardizedFileURL
            guard candidate.deletingLastPathComponent() == root,
                  expectedFilenames.contains(candidate.lastPathComponent) else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        if let enumerationError { throw enumerationError }
    }

    /// Reads at most one byte beyond the statted/indexed length, preventing a
    /// concurrent file replacement from turning a bounded cache read into an
    /// unbounded allocation.
    private static func readExactFile(
        at url: URL,
        expectedByteCount: Int
    ) throws -> Data {
        guard expectedByteCount >= 0, expectedByteCount < Int.max else {
            throw CocoaError(.fileReadTooLarge)
        }
        let handle = try FileHandle(forReadingFrom: url)
        let readLimit = expectedByteCount + 1
        do {
            var data = Data()
            while data.count < readLimit {
                let chunk = try handle.read(
                    upToCount: min(1_024 * 1_024, readLimit - data.count)
                ) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            try handle.close()
            guard data.count == expectedByteCount else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        } catch let readError {
            do {
                try handle.close()
            } catch {
                throw CocoaError(
                    .fileReadUnknown,
                    userInfo: [NSUnderlyingErrorKey: readError]
                )
            }
            throw readError
        }
    }

    private static func hashedFilename(for key: String) -> String {
        let hash = SHA256.hash(data: Data(key.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
