import Foundation
import ImageIO
import UIKit

struct DecodedImageCacheLease: Equatable, Sendable {
    fileprivate let identity: String
    fileprivate let generation: UInt64
}

struct DecodedImageCacheKey: Hashable, Sendable {
    enum Kind: String, Sendable {
        case artworkDisplay
        case artworkThumbnail
        case childPhotoDisplay
        case childPhotoThumbnail
        case photoArchiveThumbnail
    }

    let kind: Kind
    let resourceID: String
    let maximumPixelSize: Int
    let displayScaleMilliunits: Int

    init(
        kind: Kind,
        resourceID: String,
        maximumPixelSize: Int,
        displayScale: CGFloat
    ) {
        self.kind = kind
        self.resourceID = resourceID
        self.maximumPixelSize = maximumPixelSize
        displayScaleMilliunits = Int((displayScale * 1_000).rounded())
    }
}

private actor DecodedImageLoadGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < limit {
            active += 1
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
            return
        }
        active = max(0, active - 1)
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

/// Owns NotificationCenter's non-Sendable observer token behind a lock. The
/// center may invalidate an observer from any thread during teardown, while the
/// cache callback itself is always handed back to the main actor.
private final class DecodedImageMemoryWarningObservation: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func start(handler: @escaping @MainActor @Sendable () -> Void) {
        let newToken = notificationCenter.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in handler() }
        }
        let replacedToken = lock.withLock { () -> NSObjectProtocol? in
            defer { token = newToken }
            return token
        }
        if let replacedToken {
            notificationCenter.removeObserver(replacedToken)
        }
    }

    func cancel() {
        let oldToken = lock.withLock { () -> NSObjectProtocol? in
            defer { token = nil }
            return token
        }
        if let oldToken {
            notificationCenter.removeObserver(oldToken)
        }
    }

    deinit {
        cancel()
    }
}

/// The single decoded-image budget shared by family photo, artwork, yearbook and
/// dashboard surfaces. Views retain only images that are currently on-screen;
/// this cache provides bounded reuse when those cells reappear.
@MainActor
final class DecodedImageCache {
    struct Limits: Equatable, Sendable {
        var maximumDecodedBytes = 96 * 1_024 * 1_024
        var maximumEntries = 160
        var maximumConcurrentLoads = 6
        var maximumSourcePixels = 100_000_000
        var maximumSourceDimension = 65_535
    }

    struct Snapshot: Equatable, Sendable {
        let entryCount: Int
        let decodedBytes: Int
        let hasActiveOwner: Bool
        let generation: UInt64
    }

    static let shared = DecodedImageCache()

    private struct Entry {
        let image: UIImage
        let decodedBytes: Int
        var lastAccess: UInt64
    }

    /// ImageIO creates the image completely inside the detached decode task.
    /// The immutable result is transferred once to MainActor and never mutated.
    private struct SendableImage: @unchecked Sendable {
        let value: UIImage
    }

    private let limits: Limits
    private let displayScale: CGFloat
    private let gate: DecodedImageLoadGate
    private let memoryWarningObservation: DecodedImageMemoryWarningObservation?
    private var activeLease: DecodedImageCacheLease?
    private var generation: UInt64 = 0
    private var accessCounter: UInt64 = 0
    private var entries: [DecodedImageCacheKey: Entry] = [:]
    private var decodedBytes = 0

    init(
        limits: Limits = Limits(),
        displayScale: CGFloat? = nil,
        notificationCenter: NotificationCenter = .default,
        observesMemoryWarnings: Bool = true
    ) {
        self.limits = Limits(
            maximumDecodedBytes: max(1, limits.maximumDecodedBytes),
            maximumEntries: max(1, limits.maximumEntries),
            maximumConcurrentLoads: max(1, limits.maximumConcurrentLoads),
            maximumSourcePixels: max(1, limits.maximumSourcePixels),
            maximumSourceDimension: max(1, limits.maximumSourceDimension)
        )
        self.displayScale = max(1, displayScale ?? UIScreen.main.scale)
        gate = DecodedImageLoadGate(limit: limits.maximumConcurrentLoads)
        let observation =
            observesMemoryWarnings
            ? DecodedImageMemoryWarningObservation(notificationCenter: notificationCenter)
            : nil
        memoryWarningObservation = observation
        observation?.start { [weak self] in
            self?.handleMemoryPressure()
        }
    }

    @discardableResult
    func activate(identity: String) -> DecodedImageCacheLease {
        if let activeLease, activeLease.identity == identity { return activeLease }
        generation &+= 1
        clearEntries()
        let lease = DecodedImageCacheLease(identity: identity, generation: generation)
        activeLease = lease
        return lease
    }

    func currentLease() -> DecodedImageCacheLease? {
        activeLease
    }

    /// Locks out both reads and late writes until the next authenticated owner is
    /// activated. This is used for logout, account replacement and auth locking.
    func suspend() {
        activeLease = nil
        generation &+= 1
        clearEntries()
    }

    /// Memory pressure retains the owner lease but invalidates all work that began
    /// before the warning so a completed network request cannot refill the cache.
    func handleMemoryPressure() {
        generation &+= 1
        if let activeLease {
            self.activeLease = DecodedImageCacheLease(
                identity: activeLease.identity,
                generation: generation
            )
        }
        clearEntries()
    }

    func remove(kind: DecodedImageCacheKey.Kind, resourceID: String) {
        let matchingKeys = entries.keys.filter {
            $0.kind == kind && $0.resourceID == resourceID
        }
        for key in matchingKeys {
            removeEntry(for: key)
        }
    }

    func image(
        kind: DecodedImageCacheKey.Kind,
        resourceID: String,
        maximumPixelSize: Int,
        lease: DecodedImageCacheLease,
        loader: () async throws -> Data
    ) async -> UIImage? {
        guard maximumPixelSize > 0,
            !resourceID.isEmpty,
            isCurrent(lease)
        else { return nil }

        let key = DecodedImageCacheKey(
            kind: kind,
            resourceID: resourceID,
            maximumPixelSize: maximumPixelSize,
            displayScale: displayScale
        )
        if let image = cachedImage(for: key) { return image }
        guard await gate.acquire() else { return nil }

        let result: UIImage?
        do {
            try Task.checkCancellation()
            if let cached = cachedImage(for: key) {
                result = cached
            } else {
                let data = try await loader()
                try Task.checkCancellation()
                let limits = limits
                let scale = displayScale
                let decoded = await Task.detached(priority: .userInitiated) {
                    Self.decode(
                        data,
                        maximumPixelSize: maximumPixelSize,
                        displayScale: scale,
                        limits: limits
                    )
                }.value
                try Task.checkCancellation()
                guard isCurrent(lease), let decoded else {
                    result = nil
                    await gate.release()
                    return result
                }
                insert(decoded.value, for: key)
                result = decoded.value
            }
        } catch {
            result = nil
        }
        await gate.release()
        guard !Task.isCancelled, isCurrent(lease) else { return nil }
        return result
    }

    func snapshot() -> Snapshot {
        Snapshot(
            entryCount: entries.count,
            decodedBytes: decodedBytes,
            hasActiveOwner: activeLease != nil,
            generation: generation
        )
    }

    private func isCurrent(_ lease: DecodedImageCacheLease) -> Bool {
        activeLease == lease
    }

    private func cachedImage(for key: DecodedImageCacheKey) -> UIImage? {
        guard var entry = entries[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        return entry.image
    }

    private func insert(_ image: UIImage, for key: DecodedImageCacheKey) {
        guard let bytes = Self.decodedCost(of: image),
            bytes <= limits.maximumDecodedBytes
        else { return }
        removeEntry(for: key)
        while !entries.isEmpty,
            entries.count >= limits.maximumEntries
                || decodedBytes > limits.maximumDecodedBytes - bytes
        {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else {
                break
            }
            removeEntry(for: oldest.key)
        }
        accessCounter &+= 1
        entries[key] = Entry(image: image, decodedBytes: bytes, lastAccess: accessCounter)
        decodedBytes += bytes
    }

    private func removeEntry(for key: DecodedImageCacheKey) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        decodedBytes = max(0, decodedBytes - entry.decodedBytes)
    }

    private func clearEntries() {
        entries.removeAll(keepingCapacity: false)
        decodedBytes = 0
        accessCounter = 0
    }

    nonisolated private static func decodedCost(of image: UIImage) -> Int? {
        guard let cgImage = image.cgImage else { return nil }
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow || cost <= 0 ? nil : cost
    }

    nonisolated private static func decode(
        _ data: Data,
        maximumPixelSize: Int,
        displayScale: CGFloat,
        limits: Limits
    ) -> SendableImage? {
        guard !data.isEmpty,
            maximumPixelSize > 0,
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0,
            width <= limits.maximumSourceDimension,
            height <= limits.maximumSourceDimension
        else { return nil }
        let (sourcePixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, sourcePixels <= limits.maximumSourcePixels else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ),
            thumbnail.width <= maximumPixelSize,
            thumbnail.height <= maximumPixelSize
        else { return nil }
        return SendableImage(
            value: UIImage(cgImage: thumbnail, scale: displayScale, orientation: .up)
        )
    }
}
