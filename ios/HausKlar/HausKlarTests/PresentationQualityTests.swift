import Foundation
import XCTest

@testable import HausKlar

final class PresentationQualityTests: XCTestCase {
    func testReleaseCriticalAccessibilityIdentifiersAreStableAndUnique() {
        let identifiers = HausKlarAccessibilityID.releaseCriticalStaticValues

        XCTAssertFalse(identifiers.isEmpty)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(identifiers.allSatisfy { !$0.isEmpty && !$0.contains(" ") })
        XCTAssertEqual(HausKlarAccessibilityID.Main.offlineIndicator, "mainOfflineIndicator")
        XCTAssertEqual(HausKlarAccessibilityID.Main.moreLauncher, "mainMoreLauncher")
        XCTAssertEqual(HausKlarAccessibilityID.Main.moreCustomize, "mainMoreCustomize")
        XCTAssertEqual(HausKlarAccessibilityID.Main.moreHouse, "mainMoreHouse")
        XCTAssertEqual(HausKlarAccessibilityID.Main.moreFinance, "mainMoreFinance")
        XCTAssertEqual(HausKlarAccessibilityID.Main.tabSave, "mainTabSave")
        XCTAssertEqual(HausKlarAccessibilityID.Login.submit, "loginSubmit")
        XCTAssertEqual(HausKlarAccessibilityID.Medicine.submitDose, "medicineSubmitDose")
        XCTAssertEqual(HausKlarAccessibilityID.Documents.sourceSheet, "documentCaptureSourceSheet")
        XCTAssertEqual(HausKlarAccessibilityID.Photos.openLibrary, "photosOpenLibrary")
        XCTAssertEqual(HausKlarAccessibilityID.Capture.review, "captureReview")
        XCTAssertEqual(HausKlarAccessibilityID.FitnessPhotos.save, "fitnessProgressPhotoSave")
    }

    func testEntityIdentifiersKeepTheirStablePrefixAndExactIdentity() {
        XCTAssertEqual(
            HausKlarAccessibilityID.Medicine.typeCard("dose-type-7"),
            "medicineType-dose-type-7"
        )
        XCTAssertEqual(
            HausKlarAccessibilityID.Photos.photo("moment-4"),
            "photo-moment-4"
        )
        XCTAssertEqual(
            HausKlarAccessibilityID.FitnessPhotos.comparisonSelection("photo-9"),
            "fitnessProgressPhotoCompare-photo-9"
        )
    }

    func testFitnessNavigationAllowsMoreWidthAtAccessibilityTextSizes() {
        XCTAssertEqual(
            FitnessPrimaryNavigationLayout.itemWidth(isAccessibilitySize: false),
            FitnessPrimaryNavigationLayout.minimumItemWidth
        )
        XCTAssertGreaterThan(
            FitnessPrimaryNavigationLayout.itemWidth(isAccessibilitySize: true),
            FitnessPrimaryNavigationLayout.minimumItemWidth
        )
        XCTAssertGreaterThanOrEqual(
            FitnessPrimaryNavigationLayout.itemWidth(isAccessibilitySize: true),
            44
        )
    }

    func testTabBarKeepsThreeFixedDestinationsAndResolvesTwoOwnerChoices() {
        XCTAssertNil(CustomTabDestination(appTab: .today))
        XCTAssertNil(CustomTabDestination(appTab: .calendar))
        XCTAssertNil(CustomTabDestination(appTab: .family))

        XCTAssertEqual(
            TabBarPreferencePolicy.resolve(
                saved: nil,
                hasFamilyAccount: true,
                fitnessEnabled: false,
                fitnessPinned: false
            ),
            [.lists, .house]
        )
        XCTAssertEqual(
            TabBarPreferencePolicy.resolve(
                saved: nil,
                hasFamilyAccount: true,
                fitnessEnabled: true,
                fitnessPinned: true
            ),
            [.lists, .fitness]
        )
        XCTAssertEqual(
            TabBarPreferencePolicy.resolve(
                saved: [.finance, .house],
                hasFamilyAccount: true,
                fitnessEnabled: true,
                fitnessPinned: false
            ),
            [.finance, .house]
        )
        XCTAssertEqual(
            TabBarPreferencePolicy.visible(
                preferred: [.lists, .house],
                selectedTab: .finance,
                available: [.lists, .house, .finance]
            ),
            [.lists, .finance],
            "An unpinned deep link temporarily replaces one optional slot"
        )
        XCTAssertEqual(
            TabBarPreferencePolicy.visible(
                preferred: [.finance, .fitness],
                selectedTab: .today,
                available: [.lists, .house]
            ),
            [.lists, .house],
            "Unavailable saved choices must never leak into the tab bar"
        )
    }

    @MainActor
    func testMoreRoutesOnlyToDestinationsAvailableForTheSignedInUser() {
        let appState = AppState()
        appState.currentUser = UserProfile(
            id: "adult-a",
            name: "Adult",
            email: "adult@example.invalid",
            role: "user",
            priority: 10,
            familyId: "family-a"
        )

        appState.openCustomTab(.finance)
        XCTAssertEqual(appState.selectedTab, .finance)

        appState.openCustomTab(.fitness)
        XCTAssertEqual(
            appState.selectedTab,
            .finance,
            "Disabled private workspaces must not become reachable through More"
        )
    }

    func testAppLocalisationsHaveMatchingUniqueKeys() throws {
        let english = try localisationKeys(language: "en")
        let german = try localisationKeys(language: "de")

        XCTAssertEqual(english.duplicates, [], "English localisation keys must be unique")
        XCTAssertEqual(german.duplicates, [], "German localisation keys must be unique")
        XCTAssertEqual(english.keys, german.keys)
    }

    func testReleaseCriticalPresentationCopyIsLocalised() throws {
        let english = try localisationKeys(language: "en").keys
        let criticalKeys: Set<String> = [
            "Offline — changes will sync when connected",
            "Signing in",
            "Sign-in error",
            "Saved-Limit Warnings",
            "Saved-limit summary unavailable. Review dose history before recording.",
            "Preparing document…",
            "Add original file",
            "Loading moments…",
            "Camera dates are retained automatically. HausKlar makes smaller copies only for fast browsing.",
            "What needs adding or sorting out?",
            "You will check every change before anything is added.",
            "Check before adding",
            "More destinations",
            "Open unpinned destinations, tab bar choices and account settings",
            "Customise tab bar",
            "Preparing Fitness…",
            "Private originals are encrypted for your account. Preview images are protected and can be recreated. Photo bytes are never sent to Coach.",
        ]

        XCTAssertTrue(
            criticalKeys.isSubset(of: english),
            "Missing release-critical localisation keys: \(criticalKeys.subtracting(english).sorted())"
        )
    }

    private func localisationKeys(language: String) throws -> (
        keys: Set<String>, duplicates: [String]
    ) {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory.deletingLastPathComponent()
        let stringsURL =
            projectDirectory
            .appendingPathComponent("HausKlar", isDirectory: true)
            .appendingPathComponent("\(language).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings", isDirectory: false)
        let contents = try String(contentsOf: stringsURL, encoding: .utf8)
        let pattern = #"^\s*\"((?:\\.|[^\"])*)\"\s*="#
        let expression = try NSRegularExpression(pattern: pattern)
        var orderedKeys: [String] = []

        for line in contents.split(whereSeparator: \.isNewline) {
            let value = String(line)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = expression.firstMatch(in: value, range: range),
                let keyRange = Range(match.range(at: 1), in: value)
            else { continue }
            orderedKeys.append(String(value[keyRange]))
        }

        let counts = Dictionary(grouping: orderedKeys, by: { $0 }).mapValues(\.count)
        let duplicates = counts.compactMap { key, count in count > 1 ? key : nil }.sorted()
        return (Set(orderedKeys), duplicates)
    }
}
