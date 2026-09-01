import XCTest

@testable import HausKlar

final class OwnerScopedPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OwnerScopedPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPurgeRemovesExactOldOwnerInventoryWithoutTouchingNewOwner() {
        let oldIdentity = "family-a:user-a"
        let newIdentity = "family-b:user-b"
        for key in OwnerScopedPreferences.currentOwnerFixedKeys
            + OwnerScopedPreferences.dynamicKeys(identity: oldIdentity)
            + OwnerScopedPreferences.dynamicKeys(identity: newIdentity)
        {
            defaults.set("value", forKey: key)
        }

        OwnerScopedPreferences.purge(identity: oldIdentity, defaults: defaults)

        for key in OwnerScopedPreferences.currentOwnerFixedKeys
            + OwnerScopedPreferences.dynamicKeys(identity: oldIdentity)
        {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        for key in OwnerScopedPreferences.dynamicKeys(identity: newIdentity) {
            XCTAssertNotNil(defaults.object(forKey: key), key)
        }
    }

    func testMalformedLegacyIdentityNeverTriggersPrefixDeletion() {
        let anotherOwnerKey = OwnerScopedPreferences.napLastChild(identity: "family-b:user-b")
        defaults.set("child-b", forKey: anotherOwnerKey)
        defaults.set("unknown", forKey: "nap.lastChild.malformed")

        XCTAssertTrue(OwnerScopedPreferences.dynamicKeys(identity: "malformed").isEmpty)
        OwnerScopedPreferences.purge(identity: "malformed", defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: anotherOwnerKey), "child-b")
        XCTAssertEqual(defaults.string(forKey: "nap.lastChild.malformed"), "unknown")
    }

    func testWorkspaceAndFinanceKeysMatchExistingOwnerContract() {
        XCTAssertEqual(
            OwnerScopedPreferences.fitnessWorkspace(familyID: "family-a", userID: "user-a"),
            "fitness.workspace.preference.family-a.user-a"
        )
        XCTAssertEqual(
            OwnerScopedPreferences.financeScope(userID: "user-a"),
            "hausklar.finance.scope.user-a"
        )
        XCTAssertEqual(
            OwnerScopedPreferences.mainTabSlots(identity: "family-a:user-a"),
            "main.tab.slots.family-a:user-a"
        )
        XCTAssertEqual(
            OwnerScopedPreferences.napReminderMinutes(identity: "family-a:user-a"),
            "nap.reminderMinutes.family-a:user-a"
        )
        XCTAssertEqual(
            OwnerScopedPreferences.fitnessCalendarPending(identity: "family-a:user-a"),
            "fitness.calendar.pending.family-a:user-a"
        )
    }
}
