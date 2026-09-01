import XCTest
@testable import HausKlar

final class NotificationServiceTests: XCTestCase {

    func testSharedInstanceExists() {
        XCTAssertNotNil(NotificationService.shared)
    }

    func testSendSecurityAlertDoesNotCrash() {
        // Just verify it doesn't throw/crash
        NotificationService.shared.sendSecurityAlert(title: "Test", body: "Test body")
    }

    func testSendAnomalyAlertDoesNotCrash() {
        NotificationService.shared.sendAnomalyAlert(title: "Test", body: "Test body")
    }

    func testSetupCategoriesDoesNotCrash() {
        NotificationService.shared.setupCategories()
    }

    func testAuthorizationStatusDoesNotCrash() async {
        _ = await NotificationService.shared.authorizationStatus()
    }
}
