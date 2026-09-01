import Foundation
import os
import WidgetKit

/// Debounces widget timeline reloads so a burst of mutations triggers one refresh.
/// The only mutable field is serialized by `lock`; the scheduled task captures
/// immutable request values and never accesses `pending` directly.
final class WidgetReloader: @unchecked Sendable {
    static let shared = WidgetReloader()

    private let lock = NSLock()
    private var pending: Task<Void, Never>?

    private init() {}

    func requestReload(after delay: TimeInterval = 2) {
        lock.withLock {
            pending?.cancel()
            let ownerIdentity = GlanceStore.activeIdentity
            pending = Task {
                let boundedDelay = delay.isFinite ? min(max(0, delay), 60) : 0
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(boundedDelay * 1_000_000_000)
                    )
                } catch {
                    // Cancellation is the debounce mechanism, not an error.
                    return
                }
                guard !Task.isCancelled,
                      GlanceStore.activeIdentity == ownerIdentity else { return }

                // Publish the fresh glance immediately. If its memory asset has
                // changed, the asset-scoped lookup simply omits the image until
                // the bounded derivative below is ready.
                WidgetCenter.shared.reloadAllTimelines()

                if let ownerIdentity,
                   await GlanceRefresher.prepareCachedMemoryThumbnail(
                       ownerIdentity: ownerIdentity
                   ) {
                    guard !Task.isCancelled,
                          GlanceStore.activeIdentity == ownerIdentity else { return }
                    // A second reload publishes only the newly validated 160 px
                    // derivative; the widget never observes the source bytes.
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
    }
}

/// Refreshes the shared glance cache that widgets read from the App Group container.
/// Failures are silent — widgets fall back to their own cached copy.
enum GlanceRefresher {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "GlanceRefresher"
    )

    static func refresh() async {
        guard let glanceOwner = GlanceStore.activeIdentity else { return }
        do {
            let glance: GlanceDTO = try await APIClient.shared.get(
                "/briefing/glance",
                queryItems: [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)],
                bypassCache: true
            )
            await prepareMemoryThumbnail(for: glance, ownerIdentity: glanceOwner)
            guard GlanceStore.activeIdentity == glanceOwner else { return }
            GlanceStore.save(glance, for: glanceOwner)
            WidgetReloader.shared.requestReload(after: 0.5)
        } catch {
            // Endpoint unavailable or offline — nothing to update.
        }
    }

    @discardableResult
    static func prepareCachedMemoryThumbnail(ownerIdentity: String) async -> Bool {
        guard GlanceStore.activeIdentity == ownerIdentity,
              let cached = GlanceStore.load() else { return false }
        return await prepareMemoryThumbnail(
            for: cached.glance,
            ownerIdentity: ownerIdentity
        )
    }

    @discardableResult
    static func prepareMemoryThumbnail(
        for glance: GlanceDTO,
        ownerIdentity: String
    ) async -> Bool {
        guard GlanceStore.activeIdentity == ownerIdentity else { return false }
        guard let memory = glance.memory,
              BoundedHTTPPayload.isValidOpaqueIdentifier(memory.assetId) else {
            do {
                return try GlanceStore.clearMemoryThumbnails(for: ownerIdentity)
            } catch {
                logger.error(
                    "Could not clear an obsolete owner-scoped widget thumbnail: \(error.localizedDescription, privacy: .public). Reconciliation: the next glance refresh retries the same owner directory."
                )
                return false
            }
        }
        if GlanceStore.loadMemoryThumbnail(assetId: memory.assetId) != nil {
            return false
        }

        do {
            let sourceURL = try await APIClient.shared.downloadToTemporaryFile(
                "/photos/\(memory.assetId)/thumbnail?size=preview",
                filename: "memory-\(memory.assetId).source",
                maximumBytes: GlanceMemoryThumbnailPipeline.maximumSourceBytes,
                allowedMediaTypes: [
                    "image/jpeg",
                    "image/png",
                    "image/webp",
                    "image/heic",
                    "image/heif",
                ]
            )
            defer { removeOwnedTemporaryDownload(sourceURL) }
            try Task.checkCancellation()
            let derivative = try GlanceMemoryThumbnailPipeline.makeDerivative(
                from: sourceURL
            )
            try Task.checkCancellation()
            guard GlanceStore.activeIdentity == ownerIdentity else { return false }
            return GlanceStore.saveMemoryThumbnail(
                derivative,
                assetId: memory.assetId,
                for: ownerIdentity
            )
        } catch {
            // A cancellation or transient download/decoder failure must not
            // evict a valid derivative for another cached glance. Asset-scoped
            // reads already prevent stale bytes from being displayed.
            return false
        }
    }

    private static func removeOwnedTemporaryDownload(_ fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let transferRoot = APIClient.shared.transferTemporaryRoot.standardizedFileURL
        guard directory.deletingLastPathComponent() == transferRoot,
              directory.lastPathComponent.hasPrefix("download-") else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                logger.error(
                    "Could not remove a widget download file: \(error.localizedDescription, privacy: .public). Reconciliation: API transfer startup cleanup retries bounded interrupted downloads."
                )
            }
            return
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            logger.error(
                "Could not remove a widget download directory: \(error.localizedDescription, privacy: .public). Reconciliation: API transfer startup cleanup retries bounded interrupted downloads."
            )
        }
    }
}
