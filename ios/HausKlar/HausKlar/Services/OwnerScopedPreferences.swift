import Foundation

/// Exact inventory of small family-derived preferences that live outside the
/// database. Purging uses concrete old-owner keys only; it never deletes a
/// prefix that could include a different signed-in family.
enum OwnerScopedPreferences {
    static let currentOwnerFixedKeys = [
        "homework.children.cache",
        "homework.reading.cache",
        "homework.spellings.cache",
        "homework.selectedChild",
        "presents.selectedChild",
        "favorite_scenes",
        HomeSnapshotCacheKeys.states,
        HomeSnapshotCacheKeys.timestamp,
        HomeSnapshotCacheKeys.manifest,
        HomeSnapshotCacheKeys.sitrep,
    ]

    static func napLastChild(identity: String) -> String {
        "nap.lastChild.\(identity)"
    }

    static func napLastLocation(identity: String) -> String {
        "nap.lastLocation.\(identity)"
    }

    static func napReminderMinutes(identity: String) -> String {
        "nap.reminderMinutes.\(identity)"
    }

    static func fitnessCalendarPlanned(identity: String) -> String {
        "fitness.calendar.planned.\(identity)"
    }

    static func fitnessCalendarCompleted(identity: String) -> String {
        "fitness.calendar.completed.\(identity)"
    }

    static func fitnessCalendarPending(identity: String) -> String {
        "fitness.calendar.pending.\(identity)"
    }

    static func fitnessWorkspace(familyID: String?, userID: String) -> String {
        "fitness.workspace.preference.\(familyID ?? "personal").\(userID)"
    }

    static func financeScope(userID: String) -> String {
        "hausklar.finance.scope.\(userID)"
    }

    static func mainTabSlots(identity: String) -> String {
        "main.tab.slots.\(identity)"
    }

    static func dynamicKeys(identity: String) -> [String] {
        guard let parts = identityParts(identity) else { return [] }
        return [
            napLastChild(identity: identity),
            napLastLocation(identity: identity),
            napReminderMinutes(identity: identity),
            fitnessCalendarPlanned(identity: identity),
            fitnessCalendarCompleted(identity: identity),
            fitnessCalendarPending(identity: identity),
            fitnessWorkspace(
                familyID: parts.familyID == "no-family" ? nil : parts.familyID,
                userID: parts.userID
            ),
            financeScope(userID: parts.userID),
            mainTabSlots(identity: identity),
        ]
    }

    static func purge(identity: String?, defaults: UserDefaults) {
        for key in currentOwnerFixedKeys {
            defaults.removeObject(forKey: key)
        }
        guard let identity else { return }
        for key in dynamicKeys(identity: identity) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func identityParts(_ identity: String) -> (familyID: String, userID: String)? {
        guard let separator = identity.lastIndex(of: ":") else { return nil }
        let familyID = String(identity[..<separator])
        let userID = String(identity[identity.index(after: separator)...])
        guard !familyID.isEmpty,
            !userID.isEmpty,
            familyID.utf8.count <= 160,
            userID.utf8.count <= 160
        else { return nil }
        return (familyID, userID)
    }
}

enum HomeSnapshotCacheKeys {
    static let states = "cachedEntityStates"
    static let timestamp = "cachedEntityTimestamp"
    static let manifest = "cachedHomeManifest"
    static let sitrep = "cachedHomeSitrep"
    static let all = [states, timestamp, manifest, sitrep]
}
