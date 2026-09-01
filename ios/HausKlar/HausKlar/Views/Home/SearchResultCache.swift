import Foundation

/// In-memory cache for Spotify search results (5-min TTL, max 50 entries).
@MainActor
final class SearchResultCache {
    static let shared = SearchResultCache()
    private var cache: [String: (items: [HomeViewModel.BrowseItem], ts: Date)] = [:]
    private let ttl: TimeInterval = 300  // 5 minutes
    private let maxEntries = 50

    func get(key: String) -> [HomeViewModel.BrowseItem]? {
        guard let entry = cache[key], Date().timeIntervalSince(entry.ts) < ttl else { return nil }
        return entry.items
    }

    func set(key: String, items: [HomeViewModel.BrowseItem]) {
        cache[key] = (items: items, ts: Date())
        if cache.count > maxEntries {
            // Evict oldest entry
            if let oldest = cache.min(by: { $0.value.ts < $1.value.ts })?.key {
                cache.removeValue(forKey: oldest)
            }
        }
    }

    func clear() {
        cache.removeAll()
    }
}
