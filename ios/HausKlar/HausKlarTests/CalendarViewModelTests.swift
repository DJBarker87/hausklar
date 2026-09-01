import XCTest
@testable import HausKlar

final class FirstFamilyExperienceTests: XCTestCase {
    func testOnboardingReachesPlannerBeforeHouseholdAdministration() {
        XCTAssertEqual(
            FirstFamilyOnboardingStep.allCases,
            [.welcome, .firstCommitment, .people, .preferences]
        )
    }

    func testOnboardingShowsEveryReminderPreferenceThatItSaves() {
        XCTAssertEqual(
            Set(OnboardingReminderChoice.allCases),
            Set([.commitments, .tasks, .morningSummary, .eveningSummary])
        )
    }

    func testNativeSetupOffersOnlyModulesItCanActuallyConfigure() {
        XCTAssertEqual(OnboardingModuleDTO.nativeSetupChoices, [.fitness])
    }

    func testFirstCommitmentDefaultsToThirtyMinutes() {
        XCTAssertEqual(FirstCommitmentDuration.defaultDuration.rawValue, 30)
    }

    @MainActor
    func testQuietCareStateCanStayOutOfTheFamilyCard() {
        let viewModel = ChildrenSummaryViewModel()
        viewModel.todayAvailable = true

        let state = viewModel.careState(for: "child")

        XCTAssertTrue(state.isQuiet)
        XCTAssertEqual(state.text, "Care is quiet")
    }

    @MainActor
    func testUnavailableCareRemainsVisibleInsteadOfLookingQuiet() {
        let viewModel = ChildrenSummaryViewModel()
        viewModel.todayAvailable = false

        XCTAssertFalse(viewModel.careState(for: "child").isQuiet)
    }
}

@MainActor
final class CalendarViewModelTests: XCTestCase {

    private func makeIdentifiedViewModel() -> CalendarViewModel {
        let client = APIClient(
            sessionConfiguration: .ephemeral,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        return CalendarViewModel(apiClient: client)
    }

    private func makeEvent(
        id: String = UUID().uuidString,
        title: String = "Test event",
        start: String,
        end: String?,
        allDay: Bool,
        assignedTo: String? = nil,
        familyMemberIds: [String]? = nil,
        affectedMemberIds: [String]? = nil,
        recurrenceRule: String? = nil,
        eventType: String? = nil
    ) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id,
            title: title,
            description: nil,
            startTime: start,
            endTime: end,
            allDay: allDay,
            recurrenceRule: recurrenceRule,
            location: nil,
            familyMemberIds: familyMemberIds,
            affectedMemberIds: affectedMemberIds,
            createdAt: "2026-07-01T00:00:00Z",
            updatedAt: "2026-07-01T00:00:00Z",
            createdBy: nil,
            assignedTo: assignedTo,
            eventType: eventType
        )
    }

    private func calendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try! XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func mondayCalendar(timeZone identifier: String) -> Calendar {
        var calendar = calendar(timeZone: identifier)
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private func shortTime(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    func testTimedEventAppearsOnEveryOverlappingDayAcrossPlannerFilters() {
        let viewModel = CalendarViewModel()
        let localCalendar = Calendar.current
        let firstDay = date(2026, 7, 14, calendar: localCalendar)
        let middleDay = date(2026, 7, 15, calendar: localCalendar)
        let finalDay = date(2026, 7, 16, calendar: localCalendar)
        let followingDay = date(2026, 7, 17, calendar: localCalendar)
        let event = makeEvent(
            id: "multi-day",
            start: ISODateParser.stringNoFractional(
                from: date(2026, 7, 14, hour: 22, calendar: localCalendar)
            ),
            end: ISODateParser.stringNoFractional(
                from: date(2026, 7, 16, hour: 2, calendar: localCalendar)
            ),
            allDay: false,
            assignedTo: "dom"
        )
        viewModel.events = [event]

        XCTAssertEqual(viewModel.eventsForColumn("__all__", on: firstDay).map(\.id), ["multi-day"])
        XCTAssertEqual(viewModel.eventsForColumn("__all__", on: middleDay).map(\.id), ["multi-day"])
        XCTAssertEqual(viewModel.eventsForColumn("__all__", on: finalDay).map(\.id), ["multi-day"])
        XCTAssertTrue(viewModel.eventsForColumn("__all__", on: followingDay).isEmpty)

        viewModel.selectedDate = middleDay
        XCTAssertEqual(viewModel.eventsForSelectedDate.map(\.id), ["multi-day"])
        XCTAssertEqual(viewModel.eventsForPerson("dom", on: middleDay).map(\.id), ["multi-day"])
    }

    func testEventEditCanReplaceAndRemoveDocumentAttachment() throws {
        let viewModel = makeIdentifiedViewModel()
        var event = makeEvent(start: "2026-07-20", end: nil, allDay: true)
        event.sourceDocumentId = "doc-old"
        event.sourceDocument = SourceDocumentDTO(
            id: "doc-old",
            title: "Old letter",
            originalFilename: "old.pdf",
            mediaType: "application/pdf",
            fileSize: 100,
            downloadUrl: "/api/documents/doc-old/content"
        )

        viewModel.beginEditing(event)
        viewModel.formSourceDocumentId = "doc-new"
        viewModel.formSourceDocument = SourceDocumentDTO(
            id: "doc-new",
            title: "New letter",
            originalFilename: "new.pdf",
            mediaType: "application/pdf",
            fileSize: 200,
            downloadUrl: "/api/documents/doc-new/content"
        )
        let replacement = try XCTUnwrap(viewModel.makeUpdateRequest())
        XCTAssertTrue(replacement.request.includedFields.contains(.sourceDocumentId))
        XCTAssertEqual(replacement.request.sourceDocumentId, "doc-new")

        viewModel.beginEditing(event)
        viewModel.formSourceDocumentId = nil
        viewModel.formSourceDocument = nil
        let removal = try XCTUnwrap(viewModel.makeUpdateRequest())
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(removal.request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["source_document_id"] is NSNull)
    }

    func testEventEditPreservesAndRelabelsSeveralDocuments() throws {
        let viewModel = makeIdentifiedViewModel()
        var event = makeEvent(start: "2026-07-20", end: nil, allDay: true)
        event.sourceDocumentId = "ticket"
        event.attachments = [
            CalendarEventAttachmentDTO(
                relationId: "relation-ticket",
                role: .ticket,
                position: 0,
                id: "ticket",
                title: "Train tickets",
                originalFilename: "tickets.pdf",
                mediaType: "application/pdf",
                fileSize: 100,
                downloadUrl: "/api/documents/ticket/content"
            ),
            CalendarEventAttachmentDTO(
                relationId: "relation-insurance",
                role: .insurance,
                position: 1,
                id: "insurance",
                title: "Travel insurance",
                originalFilename: "insurance.pdf",
                mediaType: "application/pdf",
                fileSize: 200,
                downloadUrl: "/api/documents/insurance/content"
            ),
        ]

        viewModel.beginEditing(event)
        viewModel.setFormAttachmentRole(documentId: "insurance", role: .booking)
        let update = try XCTUnwrap(viewModel.makeUpdateRequest())

        XCTAssertTrue(update.request.includedFields.contains(.attachments))
        XCTAssertEqual(
            update.request.attachments,
            [
                CalendarEventAttachmentInput(documentId: "ticket", role: .ticket),
                CalendarEventAttachmentInput(documentId: "insurance", role: .booking),
            ]
        )
        XCTAssertEqual(update.request.sourceDocumentId, "ticket")

        viewModel.removeFormAttachment(documentId: "ticket")
        let promoted = try XCTUnwrap(viewModel.makeUpdateRequest())
        XCTAssertEqual(promoted.request.sourceDocumentId, "insurance")
        XCTAssertEqual(promoted.request.attachments?.map(\.documentId), ["insurance"])
    }

    func testCalendarEventDecodesLegacyResponseWithoutAttachments() throws {
        let json = """
        {
          "id": "legacy-event",
          "title": "Synthetic public demo record 18",
          "description": null,
          "start_time": "2026-09-01",
          "end_time": null,
          "all_day": true,
          "recurrence_rule": null,
          "location": null,
          "family_member_ids": null,
          "created_at": "2026-08-01T08:00:00Z",
          "updated_at": "2026-08-01T08:00:00Z",
          "created_by": "dom",
          "assigned_to": null,
          "source_document_id": "letter"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let event = try decoder.decode(CalendarEventDTO.self, from: Data(json.utf8))

        XCTAssertEqual(event.sourceDocumentId, "letter")
        XCTAssertTrue(event.attachments.isEmpty)
    }

    func testDayPlanOrdersPrepImmediatelyBeforeEventAndUntimedWorkLast() throws {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let day = date(2026, 8, 3, calendar: london)
        let event = makeEvent(
            id: "trip",
            title: "Synthetic public demo record 18",
            start: "2026-08-03T09:00:00Z",
            end: "2026-08-03T10:00:00Z",
            allDay: false
        )
        viewModel.events = [event]
        viewModel.activeRoutines = [
            ActiveRoutineDTO(
                routineItemId: "bed",
                personId: "child",
                personName: "Child",
                name: "Bedtime",
                color: "#008080",
                date: "2026-08-03",
                timeOfDay: nil,
                location: nil,
                preparationNote: nil,
                prepTemplateId: nil,
                reminderMinutes: nil
            )
        ]
        viewModel.plannerTasks = [
            TaskDTO(
                id: "untimed",
                title: "Return form",
                description: nil,
                assignedTo: nil,
                dueDate: "2026-08-03",
                completedAt: nil,
                category: nil,
                recurrenceRule: nil,
                priority: 1,
                createdAt: "2026-08-01T00:00:00Z",
                updatedAt: "2026-08-01T00:00:00Z",
                createdBy: "dom",
                actionableFrom: nil,
                assignees: []
            )
        ]
        viewModel.plannerPrepSuggestions = [
            PrepPackSuggestionDTO(
                id: "prep-trip",
                templateId: "swim-pack",
                templateName: "Trip bag",
                eventId: "trip",
                eventTitle: "Synthetic public demo record 18",
                eventAllDay: false,
                eventStart: "2026-08-03T09:00:00Z",
                occurrenceStart: "2026-08-03T09:00:00Z",
                items: ["Water bottle"],
                leadHours: 12,
                assignedTo: nil
            )
        ]

        let items = viewModel.dayPlanItems(on: day, calendar: london)
        let prepIndex = try XCTUnwrap(items.firstIndex { $0.id == "prep:prep-trip" })
        let eventIndex = try XCTUnwrap(items.firstIndex { $0.id == "event:trip" })

        XCTAssertEqual(prepIndex + 1, eventIndex)
        XCTAssertEqual(items.last?.id, "task:untimed")
        XCTAssertFalse(items.contains { $0.id.hasPrefix("meal:") })
    }

    func testDayPlanPlacesHandoffInOneCoordinationTimeline() throws {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let day = date(2026, 8, 3, calendar: london)
        viewModel.events = [
            makeEvent(
                id: "tea",
                title: "Tea",
                start: "2026-08-03T16:00:00Z",
                end: "2026-08-03T17:00:00Z",
                allDay: false
            )
        ]
        viewModel.handoffs = [
            HandoffOccurrenceDTO(
                id: "pickup:2026-08-03",
                handoffId: "pickup",
                kind: .pickup,
                date: "2026-08-03",
                timeOfDay: "16:20",
                termPersonId: "child",
                termPersonName: "Child One",
                ownerUserId: "child",
                ownerName: "Child One",
                label: "Child One pickup",
                isOverride: false
            )
        ]

        let items = viewModel.dayPlanItems(on: day, calendar: london)
        let coordination = try XCTUnwrap(items.first { $0.id == "coordination:2026-08-03" })

        XCTAssertEqual(coordination.title, "Leave & pickup")
        XCTAssertEqual(coordination.timeLabel, "Plan")
        if case .coordination(let handoffs, let toast) = coordination.kind {
            XCTAssertEqual(handoffs.map(\.ownerUserId), ["child"])
            XCTAssertEqual(handoffs.first?.termPersonName, "Child One")
            XCTAssertTrue(toast.isEmpty)
        } else {
            XCTFail("The handoff should stay in the calm coordination timeline")
        }
    }

    func testPickupRequestsDoNotEncodeAnAdultOwner() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let pickup = HandoffScheduleItemRequest(
            kind: .pickup,
            weekday: 0,
            timeOfDay: "15:20",
            termPersonId: "child",
            ownerUserId: nil
        )
        let pickupJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(pickup)) as? [String: Any]
        )
        XCTAssertNil(pickupJSON["owner_user_id"])

        let work = HandoffScheduleItemRequest(
            kind: .workDeparture,
            weekday: 0,
            timeOfDay: "17:00",
            termPersonId: "dom",
            ownerUserId: "dom"
        )
        let workJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(work)) as? [String: Any]
        )
        XCTAssertEqual(workJSON["owner_user_id"] as? String, "dom")
    }

    func testDayPlanGroupsToastPickupWindowsIntoOneRow() throws {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let day = date(2026, 9, 15, calendar: london)
        viewModel.events = [
            makeEvent(
                id: "toast-max",
                title: "Toast · Child One",
                start: "2026-09-15T15:45:00Z",
                end: "2026-09-15T16:30:00Z",
                allDay: false,
                eventType: "toast_club"
            ),
            makeEvent(
                id: "toast-ottie",
                title: "Toast · Child Two",
                start: "2026-09-15T14:30:00Z",
                end: "2026-09-15T16:30:00Z",
                allDay: false,
                eventType: "toast_club"
            )
        ]

        let items = viewModel.dayPlanItems(on: day, calendar: london)
        let coordination = try XCTUnwrap(items.first { $0.id == "coordination:2026-09-15" })

        XCTAssertEqual(items.filter { $0.id.hasPrefix("coordination:") }.count, 1)
        if case .coordination(let handoffs, let windows) = coordination.kind {
            XCTAssertTrue(handoffs.isEmpty)
            XCTAssertEqual(windows.map(\.id), ["toast-ottie", "toast-max"])
        } else {
            XCTFail("Toast pickup windows should share the coordination timeline")
        }
    }

    func testSchoolMilestoneTypeDrivesCelebrationSurfaces() {
        let milestone = makeEvent(
            id: "ottie-first-day",
            title: "Child Two’s first day at Example Primary School",
            start: "2026-09-09T07:40:00Z",
            end: "2026-09-09T12:10:00Z",
            allDay: false,
            eventType: "school_milestone"
        )

        XCTAssertTrue(milestone.isSchoolMilestone)
        XCTAssertFalse(milestone.isToastProjection)
    }

    func testTescoHistorySummaryDecodesOnlyNormalizedFacts() throws {
        let json = #"""
        {
          "shop_count": 12,
          "line_count": 148,
          "first_purchased_at": "2025-08-01T12:00:00Z",
          "last_purchased_at": "2026-08-01T12:00:00Z",
          "last_imported_at": "2026-08-02T12:00:00Z",
          "receipt_monitoring": true,
          "price_rise_count": 1,
          "usuals": [{
            "name": "Milk",
            "shop_count": 10,
            "last_bought": "2026-08-01T12:00:00Z",
            "latest_price_pence": 145,
            "previous_price_pence": 140
          }]
        }
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let summary = try decoder.decode(
            TescoHistorySummaryDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(summary.shopCount, 12)
        XCTAssertTrue(summary.receiptMonitoring)
        XCTAssertEqual(summary.usuals.first?.name, "Milk")
        XCTAssertEqual(summary.usuals.first?.latestPricePence, 145)
    }

    func testAllDayEventUsesExclusiveEndDate() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let event = makeEvent(
            start: "2026-07-10",
            end: "2026-07-13",
            allDay: true
        )

        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 10, calendar: london), calendar: london))
        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 11, calendar: london), calendar: london))
        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 12, calendar: london), calendar: london))
        XCTAssertFalse(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 13, calendar: london), calendar: london))
    }

    func testTimedEventEndingAtMidnightDoesNotAppearOnBoundaryDay() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let event = makeEvent(
            start: ISODateParser.stringNoFractional(
                from: date(2026, 7, 10, hour: 20, calendar: london)
            ),
            end: ISODateParser.stringNoFractional(
                from: date(2026, 7, 12, hour: 0, calendar: london)
            ),
            allDay: false
        )

        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 10, calendar: london), calendar: london))
        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 11, calendar: london), calendar: london))
        XCTAssertFalse(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 12, calendar: london), calendar: london))
    }

    func testTimedOverlapUsesTheDisplayCalendarTimeZone() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let losAngeles = calendar(timeZone: "America/Los_Angeles")
        let event = makeEvent(
            start: "2026-07-14T22:30:00Z",
            end: "2026-07-15T01:30:00Z",
            allDay: false
        )

        // 23:30-02:30 in London crosses midnight; 15:30-18:30 in Los Angeles does not.
        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 15, calendar: london), calendar: london))
        XCTAssertFalse(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 15, calendar: losAngeles), calendar: losAngeles))
        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 14, calendar: losAngeles), calendar: losAngeles))
    }

    func testEventWithoutEndOnlyAppearsOnItsStartDay() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let event = makeEvent(start: "2026-07-10", end: nil, allDay: true)

        XCTAssertTrue(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 10, calendar: london), calendar: london))
        XCTAssertFalse(viewModel.eventOverlapsDay(event, containing: date(2026, 7, 11, calendar: london), calendar: london))
    }

    func testOccurrenceTimeLabelsDescribeStartMiddleAndFinalDays() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let start = date(2026, 7, 13, hour: 22, calendar: london)
        let end = date(2026, 7, 15, hour: 2, calendar: london)
        let event = makeEvent(
            start: ISODateParser.stringNoFractional(from: start),
            end: ISODateParser.stringNoFractional(from: end),
            allDay: false
        )

        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: event,
                on: date(2026, 7, 13, calendar: london),
                calendar: london
            ),
            shortTime(start, calendar: london)
        )
        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: event,
                on: date(2026, 7, 14, calendar: london),
                calendar: london
            ),
            "Continues"
        )
        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: event,
                on: date(2026, 7, 15, calendar: london),
                calendar: london
            ),
            "Until \(shortTime(end, calendar: london))"
        )
    }

    func testOccurrenceTimeLabelsPreserveContainedRangeAndHideExclusiveBoundary() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let start = date(2026, 7, 13, hour: 10, calendar: london)
        let end = date(2026, 7, 13, hour: 11, minute: 30, calendar: london)
        let contained = makeEvent(
            start: ISODateParser.stringNoFractional(from: start),
            end: ISODateParser.stringNoFractional(from: end),
            allDay: false
        )
        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: contained,
                on: date(2026, 7, 13, calendar: london),
                calendar: london
            ),
            "\(shortTime(start, calendar: london)) - \(shortTime(end, calendar: london))"
        )

        let midnightEnd = date(2026, 7, 15, hour: 0, calendar: london)
        let endingAtMidnight = makeEvent(
            start: ISODateParser.stringNoFractional(
                from: date(2026, 7, 13, hour: 22, calendar: london)
            ),
            end: ISODateParser.stringNoFractional(from: midnightEnd),
            allDay: false
        )
        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: endingAtMidnight,
                on: date(2026, 7, 14, calendar: london),
                calendar: london
            ),
            "Until midnight"
        )
        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: endingAtMidnight,
                on: date(2026, 7, 15, calendar: london),
                calendar: london
            ),
            ""
        )

        let allDay = makeEvent(
            start: "2026-07-13",
            end: "2026-07-16",
            allDay: true
        )
        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: allDay,
                on: date(2026, 7, 14, calendar: london),
                calendar: london
            ),
            "All day"
        )
        XCTAssertEqual(
            viewModel.occurrenceTimeLabel(
                for: allDay,
                on: date(2026, 7, 16, calendar: london),
                calendar: london
            ),
            ""
        )
    }

    func testMonthGridCoversSixCompleteWeeks() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        viewModel.selectedDate = date(2026, 8, 15, calendar: london)

        let dates = viewModel.monthGridDates(calendar: london)

        XCTAssertEqual(dates.count, 42)
        XCTAssertEqual(dayKey(try! XCTUnwrap(dates.first), calendar: london), "2026-07-27")
        XCTAssertEqual(dayKey(try! XCTUnwrap(dates.last), calendar: london), "2026-09-06")
    }

    func testMonthGridUsesFiveWeeksWhenMonthFits() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        viewModel.selectedDate = date(2026, 2, 14, calendar: london)

        let dates = viewModel.monthGridDates(calendar: london)

        XCTAssertEqual(dates.count, 35)
        XCTAssertEqual(dayKey(try! XCTUnwrap(dates.first), calendar: london), "2026-01-26")
        XCTAssertEqual(dayKey(try! XCTUnwrap(dates.last), calendar: london), "2026-03-01")
    }

    func testMonthGridIncludesLeapDayAndRemainsConsecutiveAcrossDST() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")

        viewModel.selectedDate = date(2028, 2, 15, calendar: london)
        let leapKeys = Set(viewModel.monthGridDates(calendar: london).map {
            dayKey($0, calendar: london)
        })
        XCTAssertTrue(leapKeys.contains("2028-02-29"))

        viewModel.selectedDate = date(2026, 3, 15, calendar: london)
        let marchDates = viewModel.monthGridDates(calendar: london)
        XCTAssertEqual(Set(marchDates.map { dayKey($0, calendar: london) }).count, marchDates.count)
        for (current, next) in zip(marchDates, marchDates.dropFirst()) {
            XCTAssertTrue(
                london.isDate(
                    try! XCTUnwrap(london.date(byAdding: .day, value: 1, to: current)),
                    inSameDayAs: next
                )
            )
        }
    }

    func testMonthEventLoadIntervalUsesExclusiveEndAfterFinalSunday() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        viewModel.viewMode = .month
        viewModel.selectedDate = date(2026, 8, 15, calendar: london)

        let interval = try! XCTUnwrap(viewModel.eventLoadInterval(calendar: london))

        XCTAssertEqual(dayKey(interval.start, calendar: london), "2026-07-27")
        XCTAssertEqual(dayKey(interval.end, calendar: london), "2026-09-07")
    }

    func testMonthDatesShareOneLoadIntervalAndWeekdaysStartMonday() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        viewModel.viewMode = .month
        viewModel.selectedDate = date(2026, 8, 3, calendar: london)
        let firstInterval = viewModel.eventLoadInterval(calendar: london)

        viewModel.selectMonthDate(date(2026, 8, 29, calendar: london))

        XCTAssertEqual(viewModel.eventLoadInterval(calendar: london), firstInterval)
        XCTAssertEqual(
            viewModel.monthWeekdaySymbols(calendar: london).first,
            london.shortStandaloneWeekdaySymbols[1]
        )
    }

    func testMonthNavigationClampsShortMonthsAndCrossesYearBoundary() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")

        viewModel.selectedDate = date(2026, 1, 31, calendar: london)
        viewModel.moveMonth(by: 1, calendar: london)
        XCTAssertEqual(dayKey(viewModel.selectedDate, calendar: london), "2026-02-28")

        viewModel.selectedDate = date(2026, 12, 15, calendar: london)
        viewModel.moveMonth(by: 1, calendar: london)
        XCTAssertEqual(dayKey(viewModel.selectedDate, calendar: london), "2027-01-15")
        XCTAssertEqual(viewModel.selectedYear, 2027)
        viewModel.moveMonth(by: -1, calendar: london)
        XCTAssertEqual(dayKey(viewModel.selectedDate, calendar: london), "2026-12-15")
        XCTAssertEqual(viewModel.selectedYear, 2026)
    }

    func testMonthSelectionStaysInMonthUntilFullDayIsOpened() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        let selected = date(2026, 8, 20, calendar: london)
        viewModel.viewMode = .month

        viewModel.selectMonthDate(selected)

        XCTAssertEqual(viewModel.viewMode, .month)
        XCTAssertTrue(london.isDate(viewModel.selectedDate, inSameDayAs: selected))

        viewModel.openSelectedDateInDayView()
        XCTAssertEqual(viewModel.viewMode, .day)
        XCTAssertTrue(london.isDate(viewModel.selectedDate, inSameDayAs: selected))
    }

    func testTodayReanchorsMonthWithoutChangingMode() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        let now = date(2027, 1, 4, hour: 9, calendar: london)
        viewModel.viewMode = .month
        viewModel.selectedYear = 2026

        viewModel.goToToday(now, calendar: london)

        XCTAssertEqual(viewModel.viewMode, .month)
        XCTAssertTrue(london.isDate(viewModel.selectedDate, inSameDayAs: now))
        XCTAssertEqual(viewModel.selectedYear, 2027)
    }

    func testMonthMapShowsMultiDayEventsOnEveryOccupiedDate() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        viewModel.selectedDate = date(2026, 8, 15, calendar: london)
        let event = makeEvent(
            id: "trip",
            start: ISODateParser.stringNoFractional(
                from: date(2026, 8, 30, hour: 22, calendar: london)
            ),
            end: ISODateParser.stringNoFractional(
                from: date(2026, 9, 1, hour: 2, calendar: london)
            ),
            allDay: false
        )
        viewModel.events = [event]

        let dates = viewModel.monthGridDates(calendar: london)
        let eventsByDay = viewModel.eventsByDay(
            for: dates,
            columnId: "__all__",
            calendar: london
        )

        for key in ["2026-08-30", "2026-08-31", "2026-09-01"] {
            let matchingDate = try! XCTUnwrap(dates.first {
                dayKey($0, calendar: london) == key
            })
            XCTAssertEqual(
                eventsByDay[london.startOfDay(for: matchingDate)]?.map(\.id),
                ["trip"]
            )
        }

        let followingDate = try! XCTUnwrap(dates.first {
            dayKey($0, calendar: london) == "2026-09-02"
        })
        XCTAssertTrue(
            eventsByDay[london.startOfDay(for: followingDate)]?.isEmpty == true
        )
    }

    func testMonthMapKeepsAllDayEndDateExclusive() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        viewModel.selectedDate = date(2026, 8, 15, calendar: london)
        viewModel.events = [
            makeEvent(
                id: "holiday",
                start: "2026-08-10",
                end: "2026-08-13",
                allDay: true
            )
        ]
        let dates = viewModel.monthGridDates(calendar: london)
        let eventsByDay = viewModel.eventsByDay(
            for: dates,
            columnId: "__all__",
            calendar: london
        )

        for key in ["2026-08-10", "2026-08-11", "2026-08-12"] {
            let matchingDate = try! XCTUnwrap(dates.first {
                dayKey($0, calendar: london) == key
            })
            XCTAssertEqual(
                eventsByDay[london.startOfDay(for: matchingDate)]?.map(\.id),
                ["holiday"]
            )
        }
        let exclusiveEnd = try! XCTUnwrap(dates.first {
            dayKey($0, calendar: london) == "2026-08-13"
        })
        XCTAssertTrue(
            eventsByDay[london.startOfDay(for: exclusiveEnd)]?.isEmpty == true
        )
    }

    func testMonthEventsRespectAffectedAdultKidsAndSharedFilters() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        let day = date(2026, 8, 12, calendar: london)
        viewModel.familyMembers = [
            FamilyMemberDTO(id: "dom", name: "Alex", memberType: "user"),
            FamilyMemberDTO(id: "kat", name: "Morgan", memberType: "user"),
            FamilyMemberDTO(id: "max", name: "Child One", memberType: "child")
        ]
        viewModel.events = [
            makeEvent(
                id: "doctor",
                title: "Doctor",
                start: "2026-08-12",
                end: nil,
                allDay: true,
                familyMemberIds: ["max"],
                affectedMemberIds: ["dom"]
            ),
            makeEvent(
                id: "shared",
                title: "Shared",
                start: "2026-08-12",
                end: nil,
                allDay: true
            )
        ]

        XCTAssertEqual(
            viewModel.eventsForColumn("dom", on: day).map(\.id),
            ["doctor"]
        )
        XCTAssertEqual(
            viewModel.eventsForColumn("__kids__", on: day).map(\.id),
            ["doctor"]
        )
        XCTAssertEqual(
            viewModel.eventsForColumn("__everyone__", on: day).map(\.id),
            ["shared"]
        )
    }

    func testMonthEventsSortAllDayBeforeTimedEvents() {
        let viewModel = CalendarViewModel()
        let london = mondayCalendar(timeZone: "Europe/London")
        let day = date(2026, 8, 12, calendar: london)
        viewModel.events = [
            makeEvent(
                id: "timed",
                start: ISODateParser.stringNoFractional(
                    from: date(2026, 8, 12, hour: 8, calendar: london)
                ),
                end: nil,
                allDay: false
            ),
            makeEvent(
                id: "all-day",
                start: "2026-08-12",
                end: nil,
                allDay: true
            )
        ]

        XCTAssertEqual(
            viewModel.eventsForColumn("__all__", on: day).map(\.id),
            ["all-day", "timed"]
        )
    }

    func testNewTimedEventDefaultsToFifteenMinutesAndTracksStart() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let firstStart = date(2026, 9, 8, hour: 10, calendar: london)
        let movedStart = date(2026, 9, 8, hour: 11, minute: 30, calendar: london)

        viewModel.prepareNewEvent(on: firstStart)
        viewModel.setFormAllDay(false)

        XCTAssertEqual(viewModel.formDurationOption, .fifteenMinutes)
        XCTAssertEqual(viewModel.formEndTime.timeIntervalSince(firstStart), 15 * 60, accuracy: 0.1)

        viewModel.setFormStartTime(movedStart, calendar: london)
        XCTAssertEqual(viewModel.formEndTime.timeIntervalSince(movedStart), 15 * 60, accuracy: 0.1)
    }

    func testChosenAndCustomDurationsSurviveStartChanges() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let start = date(2026, 9, 8, hour: 10, calendar: london)
        viewModel.prepareNewEvent(on: start)
        viewModel.setFormAllDay(false)

        viewModel.setFormDuration(.thirtyMinutes)
        let moved = date(2026, 9, 8, hour: 12, calendar: london)
        viewModel.setFormStartTime(moved, calendar: london)
        XCTAssertEqual(viewModel.formEndTime.timeIntervalSince(moved), 30 * 60, accuracy: 0.1)

        viewModel.setFormEndTime(moved.addingTimeInterval(50 * 60))
        XCTAssertEqual(viewModel.formDurationOption, .custom)
        let movedAgain = date(2026, 9, 8, hour: 13, calendar: london)
        viewModel.setFormStartTime(movedAgain, calendar: london)
        XCTAssertEqual(viewModel.formEndTime.timeIntervalSince(movedAgain), 50 * 60, accuracy: 0.1)
    }

    func testSwitchingEditedAllDayEventToTimedUsesItsOwnStart() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        let event = makeEvent(
            start: "2026-09-08",
            end: "2026-09-09",
            allDay: true
        )

        viewModel.beginEditing(event, calendar: london)
        viewModel.setFormAllDay(false)

        XCTAssertEqual(viewModel.formDurationOption, .fifteenMinutes)
        XCTAssertEqual(
            viewModel.formEndTime.timeIntervalSince(viewModel.formStartTime),
            15 * 60,
            accuracy: 0.1
        )
    }

    func testEditingEventRestoresDurationParticipantsAndOverrideMetadata() {
        let viewModel = CalendarViewModel()
        let london = calendar(timeZone: "Europe/London")
        viewModel.familyMembers = [
            FamilyMemberDTO(id: "kat", name: "Morgan", memberType: "user"),
            FamilyMemberDTO(id: "child", name: "Child", memberType: "child")
        ]
        var event = makeEvent(
            id: "imported",
            title: "Doctor",
            start: "2026-09-08T09:00:00Z",
            end: "2026-09-08T10:00:00Z",
            allDay: false,
            familyMemberIds: ["kat", "child"]
        )
        event.readOnly = true
        event.overriddenEventId = "source-event"

        viewModel.beginEditing(event, calendar: london)

        XCTAssertEqual(viewModel.editingEvent?.id, "imported")
        XCTAssertEqual(viewModel.formDurationOption, .oneHour)
        XCTAssertEqual(viewModel.formParticipantIDs, ["kat", "child"])
        XCTAssertFalse(viewModel.formWholeFamily)
        XCTAssertEqual(viewModel.editingEvent?.overriddenEventId, "source-event")
    }

    func testUpdateRequestEncodesOnlyIncludedFieldsAndExplicitNulls() throws {
        let request = UpdateCalendarEventRequest(
            title: nil,
            description: nil,
            startTime: nil,
            endTime: nil,
            allDay: nil,
            recurrenceRule: nil,
            location: nil,
            familyMemberIds: nil,
            affectedMemberIds: nil,
            assignedTo: nil,
            clientId: "device",
            clientTimestamp: "2026-09-08T08:00:00Z",
            includedFields: [.endTime, .location]
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )

        XCTAssertTrue(object["end_time"] is NSNull)
        XCTAssertTrue(object["location"] is NSNull)
        XCTAssertNil(object["family_member_ids"])
        XCTAssertNil(object["start_time"])
        XCTAssertEqual(object["client_id"] as? String, "device")
    }

    func testTitleOnlyOccurrenceEditKeepsSeriesAnchorAndExactRuleOutOfPatch() throws {
        let viewModel = makeIdentifiedViewModel()
        let london = calendar(timeZone: "Europe/London")
        var occurrence = makeEvent(
            id: "series::2026-09-22",
            title: "Swimming",
            start: "2026-09-22T16:00:00Z",
            end: "2026-09-22T17:00:00Z",
            allDay: false,
            recurrenceRule: "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;COUNT=10"
        )
        occurrence.seriesId = "series"
        occurrence.isGeneratedOccurrence = true

        viewModel.beginEditing(occurrence, calendar: london)
        let displayedStart = viewModel.formStartTime
        viewModel.setFormStartTime(displayedStart.addingTimeInterval(60 * 60), calendar: london)
        viewModel.setFormStartTime(displayedStart, calendar: london)
        viewModel.setFormRecurrence("daily")
        viewModel.setFormRecurrence("weekly")
        viewModel.formTitle = "Swimming lesson"
        let update = try XCTUnwrap(viewModel.makeUpdateRequest())

        XCTAssertEqual(update.eventId, "series")
        XCTAssertEqual(update.request.includedFields, [.title])
        XCTAssertNil(update.request.startTime)
        XCTAssertEqual(
            occurrence.recurrenceRule,
            "FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;COUNT=10"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(update.request)) as? [String: Any]
        )
        XCTAssertEqual(object["title"] as? String, "Swimming lesson")
        XCTAssertNil(object["start_time"])
        XCTAssertNil(object["recurrence_rule"])
    }

    func testRecurrenceMutationScopesUseRequiredPlainLanguageAndWireValues() {
        XCTAssertEqual(
            CalendarRecurrenceMutationScope.allCases.map(\.label),
            ["Only this event", "This and later events", "Every event in series"]
        )
        XCTAssertEqual(
            CalendarRecurrenceMutationScope.allCases.map(\.rawValue),
            ["only_this", "this_and_later", "entire_series"]
        )
    }

    func testGeneratedOccurrenceMutationContractsKeepExactOccurrenceAndChosenScope() throws {
        let viewModel = makeIdentifiedViewModel()
        var occurrence = makeEvent(
            id: "series::2026-09-22T16:00:00+00:00",
            title: "Swimming",
            start: "2026-09-22T16:00:00Z",
            end: "2026-09-22T17:00:00Z",
            allDay: false,
            recurrenceRule: "FREQ=WEEKLY;BYDAY=TU"
        )
        occurrence.seriesId = "series"
        occurrence.isGeneratedOccurrence = true
        viewModel.beginEditing(occurrence, recurrenceScope: .thisAndLater)
        XCTAssertEqual(viewModel.editingRecurrenceScope, .thisAndLater)
        viewModel.formTitle = "Swimming lesson"

        let sparseUpdate = try XCTUnwrap(viewModel.makeUpdateRequest())
        let request = try XCTUnwrap(
            viewModel.occurrenceUpdateRequest(
                for: occurrence,
                scope: .thisAndLater,
                updates: sparseUpdate.request
            )
        )
        let deletion = try XCTUnwrap(
            viewModel.recurrenceDeleteRequest(
                for: occurrence,
                scope: .onlyThis,
                now: Date(timeIntervalSince1970: 0)
            )
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let updateJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )
        let nestedUpdates = try XCTUnwrap(updateJSON["updates"] as? [String: Any])
        let deleteJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(deletion)) as? [String: Any]
        )

        XCTAssertEqual(sparseUpdate.eventId, "series")
        XCTAssertEqual(updateJSON["scope"] as? String, "this_and_later")
        XCTAssertEqual(updateJSON["occurrence_start"] as? String, "2026-09-22T16:00:00Z")
        XCTAssertEqual(nestedUpdates["title"] as? String, "Swimming lesson")
        XCTAssertEqual(deleteJSON["scope"] as? String, "only_this")
        XCTAssertEqual(deleteJSON["occurrence_start"] as? String, "2026-09-22T16:00:00Z")

        viewModel.resetForm()
        XCTAssertNil(viewModel.editingRecurrenceScope)
    }

    func testUnavailableFamilyMembersPreserveParticipantFieldsDuringOtherEdits() throws {
        let viewModel = makeIdentifiedViewModel()
        let event = makeEvent(
            id: "doctor",
            title: "Doctor",
            start: "2026-09-08T09:00:00Z",
            end: "2026-09-08T09:30:00Z",
            allDay: false,
            assignedTo: "kat",
            familyMemberIds: ["kat", "child"],
            affectedMemberIds: ["dom"]
        )
        viewModel.beginEditing(event)
        XCTAssertTrue(viewModel.eventPeopleEditingUnavailable)
        viewModel.formTitle = "Doctor appointment"

        let update = try XCTUnwrap(viewModel.makeUpdateRequest())
        XCTAssertEqual(update.request.includedFields, [.title])
        XCTAssertNil(update.request.offlinePayload["family_member_ids"])
        XCTAssertNil(update.request.offlinePayload["affected_member_ids"])
    }

    func testCycleProfileDecodesCalculatedDatesAndConsent() throws {
        let json = """
        {
          "id": "cycle-kat",
          "owner_user_id": "kat",
          "owner_name": "Morgan",
          "is_owner": true,
          "cycle_length_days": 30,
          "show_period_starts": true,
          "show_predicted_period": true,
          "show_estimated_ovulation": true,
          "share_period_starts_with_adults": true,
          "share_predicted_period_with_adults": false,
          "share_estimated_ovulation_with_adults": false,
          "latest_period_start": "2026-07-01",
          "predicted_next_period": "2026-07-31",
          "estimated_ovulation": "2026-07-17",
          "period_starts": [{
            "id": "period-1",
            "started_on": "2026-07-01",
            "created_at": "2026-07-01T08:00:00Z",
            "updated_at": "2026-07-01T08:00:00Z"
          }],
          "created_at": "2026-07-01T08:00:00Z",
          "updated_at": "2026-07-01T08:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let profile = try decoder.decode(CycleProfileDTO.self, from: Data(json.utf8))

        XCTAssertEqual(profile.cycleLengthDays, 30)
        XCTAssertTrue(profile.sharePeriodStartsWithAdults)
        XCTAssertFalse(profile.sharePredictedPeriodWithAdults)
        XCTAssertFalse(profile.shareEstimatedOvulationWithAdults)
        XCTAssertEqual(profile.latestPeriodStart, "2026-07-01")
        XCTAssertEqual(profile.predictedNextPeriod, "2026-07-31")
        XCTAssertEqual(profile.estimatedOvulation, "2026-07-17")
        XCTAssertEqual(profile.periodStarts.first?.startedOn, "2026-07-01")
    }

    func testLegacyCycleConsentDoesNotEnableNewSharingCategories() throws {
        let json="""
        {
          "id":"cycle-kat","owner_user_id":"kat","owner_name":"Morgan","is_owner":true,
          "cycle_length_days":28,"share_with_adults":true,
          "show_period_starts":true,"show_predicted_period":true,
          "show_estimated_ovulation":true,"period_starts":[],
          "created_at":"2026-07-01T08:00:00Z","updated_at":"2026-07-01T08:00:00Z"
        }
        """
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let profile=try decoder.decode(CycleProfileDTO.self,from: Data(json.utf8))
        XCTAssertTrue(profile.legacyShareWithAdults)
        XCTAssertFalse(profile.sharePeriodStartsWithAdults)
        XCTAssertFalse(profile.sharePredictedPeriodWithAdults)
        XCTAssertFalse(profile.shareEstimatedOvulationWithAdults)
    }

    func testCalculatedCycleCalendarEventIsNotOrdinaryEditableEvent() throws {
        let json = """
        {
          "id": "cycle:kat:predicted-period",
          "title": "Predicted period",
          "description": "Planning estimate",
          "start_time": "2026-07-31",
          "end_time": null,
          "all_day": true,
          "recurrence_rule": null,
          "location": null,
          "family_member_ids": ["kat"],
          "affected_member_ids": null,
          "assigned_to": "kat",
          "event_type": "cycle_predicted_period",
          "created_at": "2026-07-01T08:00:00Z",
          "updated_at": "2026-07-01T08:00:00Z",
          "created_by": "kat",
          "read_only": true
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try decoder.decode(CalendarEventDTO.self, from: Data(json.utf8))

        XCTAssertTrue(event.isCycleProjection)
        XCTAssertTrue(event.readOnly == true)
    }

    func testFinanceCalendarAndTaskProjectionsDecodeAsManagedSafeTypes() throws {
        let eventJSON = """
        {
          "id": "finance-calendar-occurrence",
          "title": "Car insurance renewal due",
          "description": "Managed in Finance.",
          "start_time": "2026-09-01",
          "end_time": null,
          "all_day": true,
          "recurrence_rule": null,
          "location": null,
          "family_member_ids": null,
          "affected_member_ids": null,
          "assigned_to": "dom",
          "event_type": "finance_commitment",
          "created_at": "2026-08-01T08:00:00Z",
          "updated_at": "2026-08-01T08:00:00Z",
          "created_by": "dom",
          "read_only": true,
          "managed_source": {
            "kind": "finance_renewal",
            "source_id": "renewal-1",
            "deep_link": "/?view=finance&section=more&renewal=renewal-1",
            "label": "Finance renewal"
          }
        }
        """
        let taskJSON = """
        {
          "id": "finance-task-occurrence",
          "title": "Review or renew Car insurance",
          "description": "Managed in Finance.",
          "assigned_to": "dom",
          "due_date": "2026-09-01",
          "completed_at": null,
          "category": "admin",
          "recurrence_rule": null,
          "priority": 2,
          "created_at": "2026-08-01T08:00:00Z",
          "updated_at": "2026-08-01T08:00:00Z",
          "created_by": "dom",
          "actionable_from": "2026-08-11",
          "assignees": [],
          "source_document_id": null,
          "source_document": null,
          "read_only": true,
          "managed_source": {
            "kind": "finance_renewal",
            "source_id": "renewal-1",
            "deep_link": "/?view=finance&section=more&renewal=renewal-1",
            "label": "Finance renewal"
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try decoder.decode(CalendarEventDTO.self, from: Data(eventJSON.utf8))
        let task = try decoder.decode(TaskDTO.self, from: Data(taskJSON.utf8))

        XCTAssertTrue(event.isFinanceManaged)
        XCTAssertEqual(event.financeCategoryLabel, "Money")
        XCTAssertTrue(event.readOnly == true)
        XCTAssertEqual(event.managedSource?.sourceId, "renewal-1")
        let expectedFinanceURL = try XCTUnwrap(
            FinanceWebRouter.configured()?.url(
                relativeFinanceDeepLink: "/?view=finance&section=more&renewal=renewal-1"
            )
        )
        XCTAssertEqual(
            event.managedSource?.financeWebURL,
            expectedFinanceURL
        )
        XCTAssertTrue(task.isFinanceManaged)
        XCTAssertTrue(task.readOnly)
        XCTAssertEqual(task.managedSource?.kind, "finance_renewal")

        let untrustedSource = ManagedSourceDTO(
            kind: "finance_renewal",
            sourceId: "renewal-1",
            deepLink: "https://example.com/?view=finance",
            label: "Finance renewal"
        )
        XCTAssertNil(untrustedSource.financeWebURL)
    }

    func testFitnessCalendarDefaultsToPlansVisibleAndCompletedHidden() {
        let suiteName = "HausKlarTests.FitnessCalendarDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = CalendarViewModel(defaults: defaults)

        viewModel.configureFitnessCalendar(
            ownerUserId: "dom",
            localIdentity: "family:dom"
        )

        XCTAssertTrue(viewModel.showFitnessPlans)
        XCTAssertFalse(viewModel.showCompletedFitness)
    }

    func testFitnessCalendarUsesOpaqueDetailIdForExactPrivateRouting() throws {
        let suiteName = "HausKlarTests.FitnessCalendarRoute.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = CalendarViewModel(defaults: defaults)
        viewModel.configureFitnessCalendar(
            ownerUserId: nil,
            localIdentity: "family:dom"
        )
        let item = FitnessCalendarLayerItem(
            id: "projection-1",
            ownerUserId: "dom",
            layerKind: "planned",
            displayTitle: "Easy run",
            sportKey: "running",
            status: "accepted",
            scheduledStartUtc: "2026-08-03T07:00:00Z",
            scheduledDate: "2026-08-03",
            timeWindowStartUtc: nil,
            timeWindowEndUtc: nil,
            durationS: 2_700,
            detailId: "planned-session-exact"
        )

        let projection = viewModel.projectFitnessCalendarItems([item])
        let event = try XCTUnwrap(projection.events.first)
        let intent = try XCTUnwrap(projection.intentsByEventId[event.id])

        XCTAssertTrue(event.isFitnessProjection)
        XCTAssertEqual(intent.destination, .plan)
        XCTAssertEqual(intent.targetId, "planned-session-exact")
        XCTAssertEqual(intent.actionKind, "open_session")
        XCTAssertEqual(event.assignedTo, "dom")
        XCTAssertEqual(event.familyMemberIds, ["dom"])
        XCTAssertEqual(event.sourceName, "Fitness")
        XCTAssertNil(event.sourceColor)
        XCTAssertEqual(event.readOnly, false)
        viewModel.familyMembers = [
            FamilyMemberDTO(id: "dom", name: "Alex", memberType: "user"),
            FamilyMemberDTO(id: "kat", name: "Morgan", memberType: "user")
        ]
        viewModel.events = projection.events
        let berlin = mondayCalendar(timeZone: "Europe/Berlin")
        let activityDay = date(2026, 8, 3, calendar: berlin)
        XCTAssertEqual(viewModel.eventsForColumn("dom", on: activityDay, calendar: berlin).map(\.id), [event.id])
        XCTAssertTrue(viewModel.eventsForColumn("kat", on: activityDay, calendar: berlin).isEmpty)
        XCTAssertTrue(viewModel.eventsForColumn("__everyone__", on: activityDay, calendar: berlin).isEmpty)
        XCTAssertFalse(event.description?.contains("planned-session-exact") == true)
    }

    func testCompletedFitnessCalendarItemRoutesToActivities() throws {
        let suiteName = "HausKlarTests.CompletedFitnessCalendarRoute.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "fitness.calendar.completed.family:dom")

        let viewModel = CalendarViewModel(defaults: defaults)
        viewModel.configureFitnessCalendar(
            ownerUserId: "dom",
            localIdentity: "family:dom"
        )
        let item = FitnessCalendarLayerItem(
            id: "completed-projection-1",
            ownerUserId: "dom",
            layerKind: "completed",
            displayTitle: "Morning run",
            sportKey: "running",
            status: "completed",
            scheduledStartUtc: "2026-08-03T07:00:00Z",
            scheduledDate: "2026-08-03",
            timeWindowStartUtc: nil,
            timeWindowEndUtc: nil,
            durationS: 2_700,
            detailId: "completed-activity-exact"
        )

        let projection = viewModel.projectFitnessCalendarItems([item])
        let event = try XCTUnwrap(projection.events.first)
        let intent = try XCTUnwrap(projection.intentsByEventId[event.id])

        XCTAssertEqual(intent.destination, .activities)
        XCTAssertEqual(intent.targetId, "completed-activity-exact")
        XCTAssertEqual(intent.actionKind, "open_activity")
        XCTAssertEqual(event.readOnly, true)
    }

    func testSchoolFacilityProjectionKeepsFamilySwimSharedAndWeightsOwnerOnly() throws {
        let viewModel = CalendarViewModel()
        viewModel.familyMembers = [
            FamilyMemberDTO(id: "dom", name: "Alex", memberType: "user"),
            FamilyMemberDTO(id: "kat", name: "Morgan", memberType: "user")
        ]
        let familySwim = FacilityCalendarLayerItemDTO(
            id: "day-1:family_swimming:0",
            layerKind: "family_swimming",
            displayTitle: "Family swimming",
            startTime: "2026-08-09T12:00:00+01:00",
            endTime: "2026-08-09T17:00:00+01:00",
            ownerUserId: nil,
            sourceDocumentId: "document-1",
            sourceTitle: "Summer 26 Permit & Staff timetable",
            location: "Example School College",
            readOnly: true
        )
        let weights = FacilityCalendarLayerItemDTO(
            id: "day-2:weights_room:0",
            layerKind: "weights_room",
            displayTitle: "Weights room",
            startTime: "2026-08-10T06:00:00+01:00",
            endTime: "2026-08-10T12:00:00+01:00",
            ownerUserId: "dom",
            sourceDocumentId: "document-1",
            sourceTitle: "Summer 26 Permit & Staff timetable",
            location: "Example School College",
            readOnly: true
        )

        let events = viewModel.projectFacilityCalendarItems([familySwim, weights])
        let swimEvent = try XCTUnwrap(events.first)
        let weightsEvent = try XCTUnwrap(events.last)

        XCTAssertTrue(swimEvent.isFacilityProjection)
        XCTAssertTrue(swimEvent.readOnly == true)
        XCTAssertNil(swimEvent.assignedTo)
        XCTAssertEqual(swimEvent.sourceDocumentId, "document-1")
        XCTAssertEqual(weightsEvent.assignedTo, "dom")
        XCTAssertEqual(weightsEvent.familyMemberIds, ["dom"])

        viewModel.events = events
        let london = mondayCalendar(timeZone: "Europe/London")
        let swimDay = date(2026, 8, 9, calendar: london)
        let weightsDay = date(2026, 8, 10, calendar: london)
        XCTAssertEqual(
            viewModel.eventsForColumn("__everyone__", on: swimDay, calendar: london).map(\.id),
            [swimEvent.id]
        )
        XCTAssertEqual(
            viewModel.eventsForColumn("dom", on: weightsDay, calendar: london).map(\.id),
            [weightsEvent.id]
        )
        XCTAssertTrue(
            viewModel.eventsForColumn("kat", on: weightsDay, calendar: london).isEmpty
        )
    }

    func testFacilitySwimmingBookingSelectionUsesTheLondonAvailabilityWindow() throws {
        var event = makeEvent(
            title: "Family swimming",
            start: "2026-08-09T12:00:00+01:00",
            end: "2026-08-09T17:00:00+01:00",
            allDay: false
        )
        event.eventType = "facility_family_swimming"

        let selection = try XCTUnwrap(FacilitySwimmingBookingSelection(event: event))

        XCTAssertEqual(selection.date, "2026-08-09")
        XCTAssertEqual(selection.start, "12:00")
        XCTAssertEqual(selection.end, "17:00")
        XCTAssertEqual(selection.sourceSurface, .calendarEvent)
    }

    func testFacilitySwimmingBookingSendsTheExactSlotToTheCalendarWorkflow() async throws {
        let recorder = CalendarBookingRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(
                    #"{"status":"booked","event_id":"event-1","title":"Swimming","start_time":"2026-08-09T13:30:00+01:00","end_time":"2026-08-09T14:30:00+01:00","location":"Example School College"}"#.utf8
                )
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://calendar-booking-\(UUID().uuidString).example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access",
            refreshToken: "refresh"
        )
        defer { client.clearSession() }

        let selection = FacilitySwimmingBookingSelection(
            date: "2026-08-09",
            window: FacilityTimeWindowDTO(start: "12:00", end: "17:00")
        )
        XCTAssertEqual(selection.sourceSurface, .todayFacilities)
        let viewModel = FacilitySwimmingBookingViewModel(
            selection: selection,
            apiClient: client
        )
        viewModel.startTime = viewModel.windowStart.addingTimeInterval(90 * 60)
        viewModel.endTime = viewModel.windowStart.addingTimeInterval(150 * 60)

        let notice = await viewModel.save()

        XCTAssertEqual(notice, "Swimming added to the family calendar.")
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/facilities/swimming-bookings")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-HausKlar-Operation-ID"))
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["date"] as? String, "2026-08-09")
        XCTAssertEqual(object["start"] as? String, "13:30")
        XCTAssertEqual(object["end"] as? String, "14:30")
        XCTAssertEqual(
            object["client_id"] as? String,
            "00000000-0000-4000-8000-000000000001"
        )
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(object["id"] as? String)))
    }

    func testFacilityWeightsBookingCreatesAStartableStrengthPlan() async throws {
        let recorder = CalendarBookingRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data(
                    #"{"status":"planned","planned_session_id":"plan-1","title":"Strength","start_time":"2026-08-10T07:00:00+01:00","end_time":"2026-08-10T08:00:00+01:00","location":"Example School College"}"#.utf8
                )
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://weights-booking-\(UUID().uuidString).example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access",
            refreshToken: "refresh"
        )
        defer { client.clearSession() }

        let selection = FacilityWeightsBookingSelection(
            date: "2026-08-10",
            window: FacilityTimeWindowDTO(start: "06:00", end: "12:00")
        )
        let viewModel = FacilityWeightsBookingViewModel(
            selection: selection,
            apiClient: client
        )
        viewModel.startTime = viewModel.windowStart.addingTimeInterval(60 * 60)
        viewModel.endTime = viewModel.windowStart.addingTimeInterval(120 * 60)

        let notice = await viewModel.save()

        XCTAssertEqual(notice, "Strength added to Calendar and Today.")
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/facilities/weights-bookings")
        let operationID = try XCTUnwrap(
            request.value(forHTTPHeaderField: "X-HausKlar-Operation-ID")
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["date"] as? String, "2026-08-10")
        XCTAssertEqual(object["start"] as? String, "07:00")
        XCTAssertEqual(object["end"] as? String, "08:00")
        XCTAssertEqual(object["id"] as? String, operationID)
        XCTAssertEqual(
            object["client_id"] as? String,
            "00000000-0000-4000-8000-000000000001"
        )
    }
}

private final class CalendarBookingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.withLock { storedRequest }
    }

    func append(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil,
           let stream = captured.httpBodyStream,
           let body = Self.read(stream) {
            captured.httpBody = body
        }
        lock.withLock { storedRequest = captured }
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
