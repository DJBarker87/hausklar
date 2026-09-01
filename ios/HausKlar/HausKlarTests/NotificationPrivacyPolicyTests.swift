import XCTest

@testable import HausKlar

final class NotificationPrivacyPolicyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "NotificationPrivacyPolicyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testUnknownOfflineAndDifferentOwnerDefaultToPrivate() {
        let store = NotificationPrivacyPolicyStore(defaults: defaults)
        XCTAssertTrue(store.privacyMode(for: nil))
        XCTAssertTrue(store.privacyMode(for: "family-a:user-a"))

        store.update(privacyMode: false, for: "family-a:user-a")
        XCTAssertFalse(store.privacyMode(for: "family-a:user-a"))
        XCTAssertTrue(store.privacyMode(for: "family-b:user-b"))
    }

    func testOnlyCurrentOwnerEnvelopeSurvivesRelaunchAndClear() {
        var store = NotificationPrivacyPolicyStore(defaults: defaults)
        store.update(privacyMode: false, for: "family-a:user-a")

        store = NotificationPrivacyPolicyStore(defaults: defaults)
        XCTAssertFalse(store.privacyMode(for: "family-a:user-a"))
        store.update(privacyMode: true, for: "family-b:user-b")
        XCTAssertTrue(store.privacyMode(for: "family-a:user-a"))
        XCTAssertTrue(store.privacyMode(for: "family-b:user-b"))

        store.clear()
        XCTAssertTrue(store.privacyMode(for: "family-b:user-b"))
    }

    func testMalformedEnvelopeFailsPrivateAndIsDiscarded() {
        defaults.set(Data("not a plist".utf8), forKey: "notificationPrivacyPolicy.v1")  // gitleaks:allow
        let store = NotificationPrivacyPolicyStore(defaults: defaults)
        XCTAssertTrue(store.privacyMode(for: "family-a:user-a"))
        XCTAssertNil(defaults.data(forKey: "notificationPrivacyPolicy.v1"))  // gitleaks:allow
    }

    func testPrivateModeExplainsTheReminderWithoutExposingFamilyNames() {
        let cases: [(NotificationPrivacyKind, String, String, NotificationDisplayContent)] = [
            (.reminder, "Private title", "Private detail", .init(title: "HausKlar reminder", body: "Something needs checking in HausKlar.")),
            (.test, "HausKlar reminders are ready", "You’ll get useful nudges based on your settings.", .init(title: "HausKlar reminders are ready", body: "You’ll get useful nudges based on your settings.")),
            (.summary, "Today in HausKlar", "2 events and 1 task need attention", .init(title: "Today in HausKlar", body: "2 events and 1 task need attention")),
            (.event, "School pickup", "Starts in 30 minutes", .init(title: "Upcoming event", body: "Starts in 30 minutes")),
            (.task, "Return school form", "Due today", .init(title: "Task due", body: "Due today")),
            (.renewal, "Car insurance", "Due in 3 days", .init(title: "Renewal due", body: "Due in 3 days")),
            (.library, "The Wild Robot", "Due back tomorrow", .init(title: "Library book due", body: "Due back tomorrow")),
            (.document, "School letter", "Private document detail", .init(title: "Document ready to review", body: "A document has suggestions ready to check.")),
            (.insight, "Private insight", "Private family detail", .init(title: "Family update", body: "HausKlar noticed something worth checking.")),
            (.vaccination, "Private child", "Private health detail", .init(title: "Vaccination reminder", body: "A vaccination is due soon.")),
            (.nap, "Is Alex still asleep?", "Private nap detail", .init(title: "Nap timer needs checking", body: "Open the active nap.")),
            (.security, "Back door open", "Private room detail", .init(title: "Security alert", body: "A security issue needs checking now.")),
            (.anomaly, "Nursery is cold", "Private room detail", .init(title: "Home alert", body: "Something at home needs checking.")),
            (.fitness, "Private workout", "Private fitness detail", .init(title: "Rest complete", body: "Your next set is ready.")),
        ]
        for (kind, title, body, expected) in cases {
            XCTAssertEqual(
                NotificationPrivacyPolicy.displayContent(
                    kind: kind,
                    title: title,
                    body: body,
                    privacyMode: true
                ),
                expected
            )
        }
    }

    func testReminderPreviewKindsMapToSpecificPrivateCopy() {
        XCTAssertEqual(NotificationPrivacyKind.reminderPreview("event"), .event)
        XCTAssertEqual(NotificationPrivacyKind.reminderPreview("task"), .task)
        XCTAssertEqual(NotificationPrivacyKind.reminderPreview("renewal"), .renewal)
        XCTAssertEqual(NotificationPrivacyKind.reminderPreview("library"), .library)
        XCTAssertEqual(NotificationPrivacyKind.reminderPreview("unknown"), .reminder)
    }

    func testConfirmedNonPrivateModePreservesOriginalContent() {
        XCTAssertEqual(
            NotificationPrivacyPolicy.displayContent(
                kind: .nap,
                title: "Is Alex still asleep?",
                body: "Open the active nap.",
                privacyMode: false
            ),
            NotificationDisplayContent(
                title: "Is Alex still asleep?",
                body: "Open the active nap."
            )
        )
    }
}
