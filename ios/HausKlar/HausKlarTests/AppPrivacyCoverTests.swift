import SwiftUI
import XCTest

@testable import HausKlar

final class AppPrivacyCoverTests: XCTestCase {
    func testAuthenticatedContentIsCoveredOutsideActiveScene() {
        XCTAssertFalse(
            AppPrivacyCoverPolicy.shouldCover(isAuthenticated: true, scenePhase: .active)
        )
        XCTAssertTrue(
            AppPrivacyCoverPolicy.shouldCover(isAuthenticated: true, scenePhase: .inactive)
        )
        XCTAssertTrue(
            AppPrivacyCoverPolicy.shouldCover(isAuthenticated: true, scenePhase: .background)
        )
    }

    func testUnauthenticatedScreenDoesNotNeedSensitiveCover() {
        XCTAssertFalse(
            AppPrivacyCoverPolicy.shouldCover(isAuthenticated: false, scenePhase: .active)
        )
        XCTAssertFalse(
            AppPrivacyCoverPolicy.shouldCover(isAuthenticated: false, scenePhase: .inactive)
        )
        XCTAssertFalse(
            AppPrivacyCoverPolicy.shouldCover(isAuthenticated: false, scenePhase: .background)
        )
    }
}
