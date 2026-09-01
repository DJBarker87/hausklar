import CryptoKit
import Foundation
import ImageIO
import os

/// Converts an untrusted photo response into the only image representation a
/// widget may consume. Source inspection is file-backed; only a single bounded
/// 160-pixel derivative is decoded and encoded into the App Group cache.
enum GlanceMemoryThumbnailPipeline {
    enum ValidationError: LocalizedError, Equatable {
        case invalidSourceFile
        case sourceSizeExceedsMaximum
        case unsupportedSourceType
        case multipleFrames
        case invalidDimensions
        case thumbnailCreationFailed
        case encodedSizeExceedsMaximum
        case invalidDerivative

        var errorDescription: String? {
            switch self {
            case .invalidSourceFile:
                "The memory image is not a safe regular file."
            case .sourceSizeExceedsMaximum:
                "The memory image exceeds the source size limit."
            case .unsupportedSourceType:
                "The memory image uses an unsupported file type."
            case .multipleFrames:
                "Animated or multi-frame memory images are not supported."
            case .invalidDimensions:
                "The memory image dimensions are invalid or unsafe."
            case .thumbnailCreationFailed:
                "The memory thumbnail could not be created."
            case .encodedSizeExceedsMaximum:
                "The memory thumbnail exceeds the widget cache limit."
            case .invalidDerivative:
                "The cached memory thumbnail is invalid."
            }
        }
    }

    static let maximumSourceBytes = 5 * 1_024 * 1_024
    static let maximumSourceDimension = 16_384
    static let maximumSourcePixels: Int64 = 50_000_000
    static let maximumPixelDimension = 160
    static let maximumPixels = Int64(maximumPixelDimension * maximumPixelDimension)
    static let maximumEncodedBytes = 128 * 1_024

    private static let jpegType = "public.jpeg"
    private static let supportedSourceTypes: Set<String> = [
        jpegType,
        "public.png",
        "org.webmproject.webp",
        "public.heic",
        "public.heif",
    ]

    static func makeDerivative(from sourceURL: URL) throws -> Data {
        let values = try sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0 else {
            throw ValidationError.invalidSourceFile
        }
        guard byteCount <= maximumSourceBytes else {
            throw ValidationError.sourceSizeExceedsMaximum
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            throw ValidationError.invalidSourceFile
        }
        try validateSource(source)

        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ValidationError.thumbnailCreationFailed
        }
        try validateDimensions(
            width: Int64(thumbnail.width),
            height: Int64(thumbnail.height),
            maximumDimension: maximumPixelDimension,
            maximumPixels: maximumPixels
        )

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded,
            jpegType as CFString,
            1,
            nil
        ) else {
            throw ValidationError.thumbnailCreationFailed
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ValidationError.thumbnailCreationFailed
        }
        let data = encoded as Data
        guard data.count <= maximumEncodedBytes else {
            throw ValidationError.encodedSizeExceedsMaximum
        }
        _ = try validatedDerivativeImage(data)
        return data
    }

    /// Revalidates shared-container bytes before the widget decodes them. A
    /// tampered cache therefore cannot turn `UIImage` into an unbounded decoder.
    static func validatedDerivativeImage(_ data: Data) throws -> CGImage {
        guard !data.isEmpty else { throw ValidationError.invalidDerivative }
        guard data.count <= maximumEncodedBytes else {
            throw ValidationError.encodedSizeExceedsMaximum
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              (CGImageSourceGetType(source) as String?)?.lowercased() == jpegType,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
            throw ValidationError.invalidDerivative
        }
        try validateDimensions(
            width: width,
            height: height,
            maximumDimension: maximumPixelDimension,
            maximumPixels: maximumPixels
        )
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw ValidationError.invalidDerivative
        }
        try validateDimensions(
            width: Int64(image.width),
            height: Int64(image.height),
            maximumDimension: maximumPixelDimension,
            maximumPixels: maximumPixels
        )
        return image
    }

    private static func validateSource(_ source: CGImageSource) throws {
        guard CGImageSourceGetCount(source) == 1 else {
            throw ValidationError.multipleFrames
        }
        guard let type = (CGImageSourceGetType(source) as String?)?.lowercased(),
              supportedSourceTypes.contains(type) else {
            throw ValidationError.unsupportedSourceType
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
            throw ValidationError.invalidDimensions
        }
        try validateDimensions(
            width: width,
            height: height,
            maximumDimension: maximumSourceDimension,
            maximumPixels: maximumSourcePixels
        )
    }

    private static func validateDimensions(
        width: Int64,
        height: Int64,
        maximumDimension: Int,
        maximumPixels: Int64
    ) throws {
        guard width > 0,
              height > 0,
              width <= Int64(maximumDimension),
              height <= Int64(maximumDimension),
              width <= Int64.max / height,
              width * height <= maximumPixels else {
            throw ValidationError.invalidDimensions
        }
    }
}

/// Snapshot of the glance payload persisted to the App Group container so the
/// widget extension can render offline or when its access token has expired.
struct CachedGlance: Codable {
    let glance: GlanceDTO
    let fetchedAt: Date
    let ownerIdentity: String
}

/// Last downloaded memory thumbnail, kept so the widget can render offline.
struct CachedMemoryThumbnail {
    let assetId: String
    let image: Data
    let decodedImage: CGImage
    let ownerIdentity: String
}

enum GlanceStore {
    /// Foundation's coders are mutable reusable reference types. The lock keeps
    /// their exact snake-case strategies reusable inside each app or widget
    /// process without exposing either coder for unsynchronised use.
    private final class CodingStore: @unchecked Sendable {
        private let lock = NSLock()
        private let decoder: JSONDecoder
        private let encoder: JSONEncoder

        init() {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            self.decoder = decoder

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            self.encoder = encoder
        }

        func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
            try lock.withLock { try decoder.decode(type, from: data) }
        }

        func encode<Value: Encodable>(_ value: Value) throws -> Data {
            try lock.withLock { try encoder.encode(value) }
        }
    }

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "GlanceStore"
    )

    static let appGroupId =
        (Bundle.main.object(forInfoDictionaryKey: "HausKlarAppGroup") as? String)
        ?? "group.org.example.hausklar"
    static let maximumGlanceCacheBytes = 2 * 1_024 * 1_024
    static let maximumMemoryThumbnailBytes =
        GlanceMemoryThumbnailPipeline.maximumEncodedBytes
    private static let filename = "glance-cache.json"
    private static let legacyMemoryThumbnailFilename = "memory-thumbnail-cache.json"
    private static let memoryThumbnailDirectoryName = "glance-memory-thumbnails"
    private static let activeOwnerKey = "glance.activeOwner"
    private static let codingStore = CodingStore()

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try codingStore.decode(type, from: data)
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try codingStore.encode(value)
    }

    private static var fileURL: URL? {
        appGroupContainerURL?.appendingPathComponent(filename)
    }

    private static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        )
    }

    private static var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    static var activeIdentity: String? {
        groupDefaults?.string(forKey: activeOwnerKey)
    }

    static func activate(identity: String) {
        guard let defaults = groupDefaults else { return }
        activate(
            identity: identity,
            defaults: defaults,
            containerURL: appGroupContainerURL
        )
    }

    static func suspend() {
        do {
            try clear()
        } catch {
            logger.error(
                "Could not clear the shared glance cache while suspending: \(error.localizedDescription, privacy: .public). Reconciliation: the owner marker is removed now and the next activation must clear the cache before publishing a new owner."
            )
        }
        groupDefaults?.removeObject(forKey: activeOwnerKey)
    }

    /// Owner changes purge both the prior glance and every thumbnail derivative
    /// before the new owner becomes visible to the extension. Hashed owner paths
    /// remain a second isolation boundary if filesystem cleanup ever fails.
    static func activate(
        identity: String,
        defaults: UserDefaults,
        containerURL: URL?,
        fileManager: FileManager = .default
    ) {
        guard defaults.string(forKey: activeOwnerKey) != identity else { return }
        do {
            if let containerURL {
                try clearCache(at: containerURL, fileManager: fileManager)
            }
        } catch {
            logger.error(
                "Refused to activate a new glance owner because prior-owner cleanup failed: \(error.localizedDescription, privacy: .public). Reconciliation: a later activation retries the same exact cache purge."
            )
            return
        }
        defaults.set(identity, forKey: activeOwnerKey)
    }

    static func save(
        _ glance: GlanceDTO,
        fetchedAt: Date = Date(),
        for ownerIdentity: String? = nil
    ) {
        guard let expectedOwner = ownerIdentity ?? activeIdentity,
              activeIdentity == expectedOwner else { return }
        guard let url = fileURL else { return }
        do {
            let data = try encode(
                CachedGlance(
                    glance: glance,
                    fetchedAt: fetchedAt,
                    ownerIdentity: expectedOwner
                )
            )
            guard data.count <= maximumGlanceCacheBytes else { return }
            try data.write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            logger.error(
                "Could not atomically persist the glance cache: \(error.localizedDescription, privacy: .public). The last verified same-owner snapshot remains authoritative."
            )
        }
    }

    static func load() -> CachedGlance? {
        // Cache decoding is an optional, fail-closed validation probe; malformed
        // bytes are never used as widget state.
        guard let expectedOwner = activeIdentity,
              let url = fileURL,
              let data = boundedCacheData(at: url, maximumBytes: maximumGlanceCacheBytes),
              let cached = try? decode(CachedGlance.self, from: data),
              cached.ownerIdentity == expectedOwner else { return nil }
        return cached
    }

    static func clear(fileManager: FileManager = .default) throws {
        guard let containerURL = appGroupContainerURL else { return }
        try clearCache(at: containerURL, fileManager: fileManager)
    }

    // MARK: - Memory thumbnail

    @discardableResult
    static func saveMemoryThumbnail(
        _ image: Data,
        assetId: String,
        for ownerIdentity: String? = nil
    ) -> Bool {
        guard let expectedOwner = ownerIdentity ?? activeIdentity,
              activeIdentity == expectedOwner,
              let containerURL = appGroupContainerURL else { return false }
        do {
            try saveMemoryThumbnail(
                image,
                assetId: assetId,
                ownerIdentity: expectedOwner,
                containerURL: containerURL
            )
            return true
        } catch {
            return false
        }
    }

    static func loadMemoryThumbnail(assetId: String) -> CachedMemoryThumbnail? {
        guard let expectedOwner = activeIdentity,
              let containerURL = appGroupContainerURL else { return nil }
        return loadMemoryThumbnail(
            assetId: assetId,
            ownerIdentity: expectedOwner,
            containerURL: containerURL
        )
    }

    @discardableResult
    static func clearMemoryThumbnails(
        for ownerIdentity: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let containerURL = appGroupContainerURL,
              let ownerDirectory = memoryThumbnailOwnerDirectoryURL(
                containerURL: containerURL,
                ownerIdentity: ownerIdentity
              ) else { return false }
        if fileManager.fileExists(atPath: ownerDirectory.path) {
            try fileManager.removeItem(at: ownerDirectory)
            return true
        }
        return false
    }

    static func memoryThumbnailFileURL(
        containerURL: URL,
        ownerIdentity: String,
        assetId: String
    ) -> URL? {
        guard let ownerDirectory = memoryThumbnailOwnerDirectoryURL(
            containerURL: containerURL,
            ownerIdentity: ownerIdentity
        ),
              BoundedHTTPPayload.isValidOpaqueIdentifier(assetId) else { return nil }
        let assetKey = digest(assetId)
        let candidate = ownerDirectory
            .appendingPathComponent("\(assetKey).jpg", isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == ownerDirectory else { return nil }
        return candidate
    }

    static func memoryThumbnailRootURL(containerURL: URL) -> URL {
        containerURL.standardizedFileURL
            .appendingPathComponent(memoryThumbnailDirectoryName, isDirectory: true)
    }

    static func saveMemoryThumbnail(
        _ image: Data,
        assetId: String,
        ownerIdentity: String,
        containerURL: URL,
        fileManager: FileManager = .default
    ) throws {
        _ = try GlanceMemoryThumbnailPipeline.validatedDerivativeImage(image)
        guard let destination = memoryThumbnailFileURL(
            containerURL: containerURL,
            ownerIdentity: ownerIdentity,
            assetId: assetId
        ), let ownerDirectory = memoryThumbnailOwnerDirectoryURL(
            containerURL: containerURL,
            ownerIdentity: ownerIdentity
        ) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = memoryThumbnailRootURL(containerURL: containerURL)
        try prepareDirectory(root, fileManager: fileManager)
        try prepareDirectory(ownerDirectory, fileManager: fileManager)
        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        try removeOtherOwnedThumbnails(
            in: ownerDirectory,
            retaining: destination,
            fileManager: fileManager
        )
        try image.write(
            to: destination,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        let stored = boundedCacheData(
            at: destination,
            maximumBytes: maximumMemoryThumbnailBytes
        )
        guard let stored, stored == image else {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func loadMemoryThumbnail(
        assetId: String,
        ownerIdentity: String,
        containerURL: URL
    ) -> CachedMemoryThumbnail? {
        // Derivative decoding is an optional, fail-closed validation probe.
        guard let url = memoryThumbnailFileURL(
            containerURL: containerURL,
            ownerIdentity: ownerIdentity,
            assetId: assetId
        ), let data = boundedCacheData(
            at: url,
            maximumBytes: maximumMemoryThumbnailBytes
        ), let decodedImage = try? GlanceMemoryThumbnailPipeline.validatedDerivativeImage(data) else {
            return nil
        }
        return CachedMemoryThumbnail(
            assetId: assetId,
            image: data,
            decodedImage: decodedImage,
            ownerIdentity: ownerIdentity
        )
    }

    static func clearCache(
        at containerURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let standardizedContainer = containerURL.standardizedFileURL
        let targets = [
            standardizedContainer.appendingPathComponent(filename),
            standardizedContainer.appendingPathComponent(legacyMemoryThumbnailFilename),
            memoryThumbnailRootURL(containerURL: standardizedContainer),
        ]
        for target in targets {
            guard target.standardizedFileURL.deletingLastPathComponent()
                    == standardizedContainer else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            guard !fileManager.fileExists(atPath: target.path) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    private static func memoryThumbnailOwnerDirectoryURL(
        containerURL: URL,
        ownerIdentity: String
    ) -> URL? {
        guard !ownerIdentity.isEmpty, ownerIdentity.utf8.count <= 1_024 else { return nil }
        let root = memoryThumbnailRootURL(containerURL: containerURL)
        let candidate = root
            .appendingPathComponent(digest(ownerIdentity), isDirectory: true)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else { return nil }
        return candidate
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func prepareDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    private static func removeOtherOwnedThumbnails(
        in ownerDirectory: URL,
        retaining destination: URL,
        fileManager: FileManager
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: ownerDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for entry in entries where entry.standardizedFileURL != destination {
            let candidate = entry.standardizedFileURL
            let values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard candidate.deletingLastPathComponent() == ownerDirectory,
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try fileManager.removeItem(at: candidate)
        }
    }

    static func boundedCacheData(
        at url: URL,
        maximumBytes: Int
    ) -> Data? {
        // Resource inspection and handle creation are fail-closed cache probes.
        guard maximumBytes > 0,
              let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumBytes,
              fileSize < Int.max,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        var data = Data()
        let readLimit = fileSize + 1
        do {
            while data.count < readLimit {
                let chunk = try handle.read(
                    upToCount: min(1_024 * 1_024, readLimit - data.count)
                ) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            try handle.close()
        } catch {
            return nil
        }
        // Reading one byte past the statted size makes a concurrent replacement
        // or growth fail closed without ever allocating the unbounded new file.
        guard data.count == fileSize else { return nil }
        return data
    }
}
