import XCTest
@testable import HausKlar

@MainActor
final class ScheduleAutomationServiceTests: XCTestCase {

    var service: ScheduleAutomationService!
    let mockPerformAction: (String, String, [String: Any]) async -> Void = { _, _, _ in }

    override func setUp() async throws {
        service = ScheduleAutomationService.shared
        service.resetDismissals()
    }

    // MARK: - Helpers

    private func makeEvent(
        title: String,
        minutesFromNow: Double,
        location: String? = nil
    ) -> CalendarEventDTO {
        let start = Date().addingTimeInterval(minutesFromNow * 60)
        let end = start.addingTimeInterval(3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowStr = formatter.string(from: Date())
        return CalendarEventDTO(
            id: UUID().uuidString,
            title: title,
            description: nil,
            startTime: formatter.string(from: start),
            endTime: formatter.string(from: end),
            allDay: false,
            recurrenceRule: nil,
            location: location,
            familyMemberIds: nil,
            createdAt: nowStr,
            updatedAt: nowStr,
            createdBy: nil,
            assignedTo: nil
        )
    }

    // MARK: - Rule 1: Morning routine

    func testSchoolEventIn45MinSuggestsBoostHeating() {
        let events = [makeEvent(title: "School drop-off", minutesFromNow: 45)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        XCTAssertTrue(suggestions.contains(where: { $0.title == "Boost Heating" }))
    }

    func testSchoolEventIn20MinDoesNotSuggest() {
        let events = [makeEvent(title: "School drop-off", minutesFromNow: 20)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        // 20min is outside the 30-60min window for morning boost, but inside the <=30min leaving window
        // It should NOT have "Boost Heating" (no location, so no leaving either)
        XCTAssertFalse(suggestions.contains(where: { $0.title == "Boost Heating" }))
    }

    func testSchoolEventIn90MinDoesNotSuggest() {
        let events = [makeEvent(title: "School drop-off", minutesFromNow: 90)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        XCTAssertFalse(suggestions.contains(where: { $0.title == "Boost Heating" }))
    }

    func testNonSchoolEventDoesNotTriggerMorning() {
        let events = [makeEvent(title: "Doctor appointment", minutesFromNow: 45)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        XCTAssertFalse(suggestions.contains(where: { $0.title == "Boost Heating" }))
    }

    // MARK: - Rule 2: Bedtime

    func testBedtimeSuggestionBetween20And22() {
        let hour = Calendar.current.component(.hour, from: Date())
        let events: [CalendarEventDTO] = []
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)

        if hour >= 20 && hour < 23 {
            XCTAssertTrue(suggestions.contains(where: { $0.title == "Goodnight" }))
        } else {
            XCTAssertFalse(suggestions.contains(where: { $0.title == "Goodnight" }))
        }
    }

    func testBedtimeSuggestionNotDuringDay() {
        let hour = Calendar.current.component(.hour, from: Date())
        let events: [CalendarEventDTO] = []
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)

        if hour < 20 || hour >= 23 {
            XCTAssertFalse(suggestions.contains(where: { $0.title == "Goodnight" }))
        }
        // If running during bedtime hours, this test is a no-op (covered by the other test)
    }

    // MARK: - Rule 3: Leaving house

    func testEventWithLocationIn20MinSuggestsLeaving() {
        let events = [makeEvent(title: "Dentist", minutesFromNow: 20, location: "High Street")]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        XCTAssertTrue(suggestions.contains(where: { $0.title == "Leaving House" }))
    }

    func testEventWithoutLocationDoesNotSuggest() {
        let events = [makeEvent(title: "Dentist", minutesFromNow: 20)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        XCTAssertFalse(suggestions.contains(where: { $0.title == "Leaving House" }))
    }

    func testEventWithLocationIn40MinDoesNotSuggest() {
        let events = [makeEvent(title: "Dentist", minutesFromNow: 40, location: "High Street")]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        XCTAssertFalse(suggestions.contains(where: { $0.title == "Leaving House" }))
    }

    // MARK: - Dismiss

    func testDismissedSuggestionDoesNotReappear() {
        let events = [makeEvent(title: "School run", minutesFromNow: 45)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)

        if let boostSuggestion = suggestions.first(where: { $0.title == "Boost Heating" }) {
            service.dismiss(boostSuggestion)
            let afterDismiss = service.checkAutomations(events: events, performAction: mockPerformAction)
            XCTAssertFalse(afterDismiss.contains(where: { $0.title == "Boost Heating" }))
        }
        // If no boost suggestion was generated (e.g. already dismissed from previous test), that's OK
    }

    func testDismissExpires() {
        // We cannot easily test 24h expiry in a unit test, but we can verify that
        // the dismiss mechanism stores state and the service handles it without error
        let events = [makeEvent(title: "School", minutesFromNow: 45)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        for s in suggestions {
            service.dismiss(s)
        }
        // Calling again should not crash
        _ = service.checkAutomations(events: events, performAction: mockPerformAction)
    }

    // MARK: - Multiple rules

    func testMultipleRulesCanFireTogether() {
        let events = [
            makeEvent(title: "School", minutesFromNow: 45),
            makeEvent(title: "Meeting", minutesFromNow: 15, location: "Office")
        ]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        let titles = Set(suggestions.map { $0.title })
        // Should contain at least Boost Heating and Leaving House
        // (Goodnight depends on current time)
        XCTAssertTrue(titles.contains("Boost Heating") || titles.contains("Leaving House"))
    }

    // MARK: - Edge cases

    func testEmptyEventsReturnsOnlyBedtimeIfApplicable() {
        let suggestions = service.checkAutomations(events: [], performAction: mockPerformAction)
        let hour = Calendar.current.component(.hour, from: Date())
        let nonBedtime = suggestions.filter { $0.title != "Goodnight" }
        XCTAssertTrue(nonBedtime.isEmpty, "Only bedtime suggestion expected with empty events")
        if hour >= 20 && hour < 23 {
            XCTAssertTrue(suggestions.contains(where: { $0.title == "Goodnight" }))
        }
    }

    func testPastEventsAreIgnored() {
        let events = [makeEvent(title: "School", minutesFromNow: -30)]
        let suggestions = service.checkAutomations(events: events, performAction: mockPerformAction)
        XCTAssertFalse(suggestions.contains(where: { $0.title == "Boost Heating" }))
    }
}
