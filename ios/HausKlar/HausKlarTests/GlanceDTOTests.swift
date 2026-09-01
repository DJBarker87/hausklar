import XCTest
@testable import HausKlar

final class GlanceDTOTests: XCTestCase {

    private func activateFitnessOwnerForDashboardTest() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GlanceDTOTests-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FitnessDatabase.shared.activateForTesting(
                identity: "glance-tests:fitness-owner",
                storeURL: root.appendingPathComponent("fitness.sqlite"),
                requiresLease: true
            )
            return root
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func deactivateFitnessOwnerForDashboardTest(at root: URL) {
        FitnessDatabase.shared.suspend()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStubbedClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        APIClientStubURLProtocol.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(sessionConfiguration: configuration)
        client.baseURL = "https://api.example.test/api"
        return client
    }

    private let contractJSON = """
    {
      "generated_at": "2026-07-12T17:00:00+00:00",
      "date": "2026-07-12",
      "events": [{"id": "e1", "title": "Swimming", "start_time": "2026-07-13T08:30:00+01:00", "all_day": false, "person_name": "Child One"}],
      "tasks_due": [{"id": "t1", "title": "Book dentist", "due_date": "2026-07-12"}],
      "dinner": {"title": "Spaghetti bolognese"},
      "medicine": [{"child_name": "Child Two", "medicine_name": "Calpol", "next_safe_at": "2026-07-12T19:45:00+00:00", "is_safe_now": false, "last_given_at": "2026-07-12T15:45:00+00:00"}],
      "tomorrow": {"first_event": {"title": "Swimming", "start_time": "2026-07-13T08:30:00+01:00", "all_day": false}, "event_count": 2}
    }
    """

    func testDecodesGlanceContract() throws {
        let glance = try GlanceStore.decode(GlanceDTO.self, from: Data(contractJSON.utf8))

        XCTAssertEqual(glance.date, "2026-07-12")
        XCTAssertEqual(glance.events.count, 1)
        XCTAssertEqual(glance.events[0].title, "Swimming")
        XCTAssertEqual(glance.events[0].personName, "Child One")
        XCTAssertFalse(glance.events[0].allDay)
        XCTAssertNotNil(ISODateParser.parse(glance.events[0].startTime))
        XCTAssertEqual(glance.tasksDue.count, 1)
        XCTAssertEqual(glance.dinner?.title, "Spaghetti bolognese")
        XCTAssertEqual(glance.medicine.count, 1)
        XCTAssertEqual(glance.medicine[0].childName, "Child Two")
        XCTAssertFalse(glance.medicine[0].isSafeNow)
        XCTAssertEqual(glance.tomorrow?.eventCount, 2)
        XCTAssertEqual(glance.tomorrow?.firstEvent?.title, "Swimming")
    }

    func testDecodesNullDinnerAndTomorrowFirstEventAndEmptyArrays() throws {
        let json = """
        {
          "generated_at": "2026-07-12T17:00:00+00:00",
          "date": "2026-07-12",
          "events": [],
          "tasks_due": [],
          "dinner": null,
          "medicine": [],
          "tomorrow": {"first_event": null, "event_count": 0}
        }
        """
        let glance = try GlanceStore.decode(GlanceDTO.self, from: Data(json.utf8))

        XCTAssertTrue(glance.events.isEmpty)
        XCTAssertTrue(glance.tasksDue.isEmpty)
        XCTAssertNil(glance.dinner)
        XCTAssertTrue(glance.medicine.isEmpty)
        XCTAssertNil(glance.tomorrow?.firstEvent)
    }

    func testMedicineStatusRequiresFreshCurrentDaySnapshotEvenWhenListIsEmpty() {
        XCTAssertFalse(GlanceMedicineStatusPolicy.needsReview(
            hasSnapshot: true,
            isStale: false,
            snapshotMatchesCurrentDay: true
        ))
        XCTAssertTrue(GlanceMedicineStatusPolicy.needsReview(
            hasSnapshot: false,
            isStale: true,
            snapshotMatchesCurrentDay: false
        ))
        XCTAssertTrue(GlanceMedicineStatusPolicy.needsReview(
            hasSnapshot: true,
            isStale: true,
            snapshotMatchesCurrentDay: true
        ))
        XCTAssertTrue(GlanceMedicineStatusPolicy.needsReview(
            hasSnapshot: true,
            isStale: false,
            snapshotMatchesCurrentDay: false
        ))
    }

    func testDecodesMemoryWhenPresent() throws {
        let json = """
        {
          "generated_at": "2026-07-12T17:00:00+00:00",
          "date": "2026-07-12",
          "events": [],
          "tasks_due": [],
          "dinner": null,
          "medicine": [],
          "tomorrow": null,
          "memory": {"asset_id": "a1", "taken_at": "2025-07-12T14:03:00+01:00", "years_ago": 1}
        }
        """
        let glance = try GlanceStore.decode(GlanceDTO.self, from: Data(json.utf8))

        XCTAssertEqual(glance.memory?.assetId, "a1")
        XCTAssertEqual(glance.memory?.yearsAgo, 1)
        XCTAssertNotNil(ISODateParser.parse(glance.memory?.takenAt ?? ""))
    }

    func testMemoryAbsentNullOrMalformedDecodesToNil() throws {
        // Absent — the deployed backend does not send the field yet.
        let absent = try GlanceStore.decode(GlanceDTO.self, from: Data(contractJSON.utf8))
        XCTAssertNil(absent.memory)

        let base = """
        {
          "generated_at": "2026-07-12T17:00:00+00:00",
          "date": "2026-07-12",
          "events": [],
          "tasks_due": [],
          "dinner": null,
          "medicine": [],
          "tomorrow": null,
          "memory": %@
        }
        """
        let null = try GlanceStore.decode(
            GlanceDTO.self, from: Data(String(format: base, "null").utf8)
        )
        XCTAssertNil(null.memory)

        let malformed = try GlanceStore.decode(
            GlanceDTO.self, from: Data(String(format: base, "{\"asset_id\": \"a1\"}").utf8)
        )
        XCTAssertNil(malformed.memory)
    }

    func testCachedGlanceRoundTrip() throws {
        let glance = try GlanceStore.decode(GlanceDTO.self, from: Data(contractJSON.utf8))
        let fetchedAt = Date(timeIntervalSince1970: 1_770_000_000)

        let data = try GlanceStore.encode(CachedGlance(
            glance: glance,
            fetchedAt: fetchedAt,
            ownerIdentity: "family:a"
        ))
        let restored = try GlanceStore.decode(CachedGlance.self, from: data)

        XCTAssertEqual(restored.fetchedAt, fetchedAt)
        XCTAssertEqual(restored.glance.events[0].id, "e1")
        XCTAssertEqual(restored.glance.medicine[0].medicineName, "Calpol")
        XCTAssertEqual(restored.glance.tomorrow?.eventCount, 2)
        XCTAssertEqual(restored.ownerIdentity, "family:a")
    }

    func testSharedGlanceCacheIsHiddenFromAnotherIdentity() throws {
        try XCTSkipIf(
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: GlanceStore.appGroupId
            ) == nil,
            "App Group is unavailable in this test environment"
        )
        defer {
            GlanceStore.suspend()
            try? GlanceStore.clear()
        }
        try? GlanceStore.clear()
        let glance = try GlanceStore.decode(GlanceDTO.self, from: Data(contractJSON.utf8))
        GlanceStore.activate(identity: "family:a")
        GlanceStore.save(glance, for: "family:a")
        XCTAssertNotNil(GlanceStore.load())

        GlanceStore.activate(identity: "family:b")

        XCTAssertNil(GlanceStore.load())
    }

    func testFinanceTodayActionDecodesAndBuildsPrivacySafePersonalLink() throws {
        let json = """
        {
          "id": "action-1",
          "kind": "HABIT_REVIEW",
          "space_id": "personal-dom",
          "space_kind": "PERSONAL",
          "space_name": "Alex private",
          "due_date": null,
          "review_date": "2026-08-02",
          "title": "Review takeaway habit",
          "amount_minor": 4200,
          "currency": "GBP",
          "source_account_id": "private-account",
          "source_account_label": "Private current account",
          "destination_account_id": null,
          "destination_account_label": null,
          "line_id": null,
          "purchase_id": null,
          "source_id": "private-source"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let action = try decoder.decode(TodayFinanceActionDTO.self, from: Data(json.utf8))

        XCTAssertEqual(action.spaceName, "Alex private")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(action.financeWebURL), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, FinanceWebRouter.configured()?.baseURL.host)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "section" })?.value, "coach")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "action" })?.value, "action-1")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "scope" })?.value, "mine")
        XCTAssertFalse(components.url?.absoluteString.contains("Private%20current") == true)
        XCTAssertFalse(components.url?.absoluteString.contains("4200") == true)
    }

    func testFinancePurchaseActionLinksToHouseholdActivityLine() throws {
        let action = TodayFinanceActionDTO(
            id: "action-2", kind: "PURCHASE_REVIEW", spaceId: "household",
            spaceKind: "HOUSEHOLD", spaceName: "Household", dueDate: nil,
            reviewDate: nil, title: nil, amountMinor: nil, currency: nil,
            sourceAccountId: nil, sourceAccountLabel: nil,
            destinationAccountId: nil, destinationAccountLabel: nil,
            lineId: "line-1", purchaseId: "purchase-1", sourceId: nil
        )

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(action.financeWebURL), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "section" })?.value, "activity")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "line" })?.value, "line-1")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "scope" })?.value, "household")
    }

    func testFitnessTodayCardDecodesExactActionsWithoutHealthDetail() throws {
        let json = """
        {
          "date": "2026-08-03",
          "has_completed_activity_today": false,
          "session": {
            "id": "planned-session-1",
            "kind": "planned_session",
            "title": "Easy run",
            "sport_key": "running",
            "status": "accepted",
            "starts_at": "2026-08-03T07:00:00Z",
            "scheduled_date": "2026-08-03",
            "duration_minutes": 45,
            "movable": true
          },
          "primary_action": {
            "kind": "open_session",
            "label": "Open",
            "destination": "plan",
            "target_id": "planned-session-1"
          },
          "secondary_action": {
            "kind": "move_session",
            "label": "Move",
            "destination": "plan",
            "target_id": "planned-session-1"
          },
          "nutrition": {
            "calories_kcal": 1425,
            "calorie_target_kcal": 2200,
            "protein_g": 96,
            "protein_target_g": 140,
            "entry_count": 5,
            "calories_complete": true,
            "protein_complete": false
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let card = try decoder.decode(FitnessTodayCardDTO.self, from: Data(json.utf8))

        XCTAssertEqual(card.session?.title, "Easy run")
        XCTAssertEqual(card.hasCompletedActivityToday, false)
        XCTAssertEqual(card.session?.durationMinutes, 45)
        XCTAssertEqual(card.primaryAction?.destination, .plan)
        XCTAssertEqual(card.primaryAction?.targetId, "planned-session-1")
        XCTAssertEqual(card.primaryAction?.label, "Open")
        XCTAssertEqual(card.secondaryAction?.kind, "move_session")
        XCTAssertEqual(card.nutrition?.caloriesKcal, 1_425)
        XCTAssertEqual(card.nutrition?.calorieTargetKcal, 2_200)
        XCTAssertEqual(card.nutrition?.proteinG, 96)
        XCTAssertEqual(card.nutrition?.proteinTargetG, 140)
        XCTAssertEqual(card.nutrition?.entryCount, 5)
        XCTAssertEqual(card.nutrition?.caloriesComplete, true)
        XCTAssertEqual(card.nutrition?.proteinComplete, false)
    }

    @MainActor
    func testFitnessOnlyRefreshUpdatesNutritionWithoutReloadingFamilyBriefing() async throws {
        let fitnessRoot = try activateFitnessOwnerForDashboardTest()
        defer { deactivateFitnessOwnerForDashboardTest(at: fitnessRoot) }
        let requestLock = NSLock()
        var requestedPaths: [String] = []
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            requestLock.withLock { requestedPaths.append(url.path) }
            XCTAssertEqual(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "date" })?.value,
                "2026-08-03"
            )
            let body = """
            {
              "date": "2026-08-03",
              "nutrition": {
                "calories_kcal": 1750,
                "calorie_target_kcal": 2100,
                "protein_g": 125,
                "protein_target_g": 120,
                "entry_count": 6,
                "calories_complete": true,
                "protein_complete": true
              }
            }
            """
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-03T12:00:00Z")! }
        )

        await viewModel.refreshFitnessTodayCard()

        XCTAssertEqual(viewModel.fitnessTodayCard?.nutrition?.caloriesKcal, 1_750)
        XCTAssertEqual(viewModel.fitnessTodayCard?.nutrition?.proteinG, 125)
        XCTAssertEqual(requestLock.withLock { requestedPaths }, ["/api/fitness/today-card"])
    }

    @MainActor
    func testFitnessOnlyRefreshRetainsLastUsefulCardWhenOffline() async throws {
        let fitnessRoot = try activateFitnessOwnerForDashboardTest()
        defer { deactivateFitnessOwnerForDashboardTest(at: fitnessRoot) }
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"Unavailable"}"#.utf8)
            )
        }
        let previous = FitnessTodayCardDTO(
            date: "2026-08-03",
            hasCompletedActivityToday: false,
            session: nil,
            primaryAction: nil,
            secondaryAction: nil,
            nutrition: FitnessTodayNutritionDTO(
                caloriesKcal: 1_600,
                calorieTargetKcal: 2_000,
                proteinG: 100,
                proteinTargetG: 120,
                entryCount: 5,
                caloriesComplete: true,
                proteinComplete: true
            )
        )
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-03T12:00:00Z")! }
        )
        viewModel.fitnessTodayCard = previous

        await viewModel.refreshFitnessTodayCard()

        XCTAssertEqual(viewModel.fitnessTodayCard, previous)
    }

    @MainActor
    func testDashboardSilentlyOmitsFitnessCardWhenItsRequestFails() async {
        let dashboardJSON = """
        {
          "generated_at": "2026-08-03T06:00:00Z",
          "date": "2026-08-03",
          "events": [],
          "tasks": [],
          "naps": [],
          "illnesses": [],
          "illness_readings": {},
          "routines": [],
          "meals": [],
          "dog": null,
          "coordination": null,
          "memories": [],
          "insights": [],
          "prep_suggestions": [],
          "medicine": [],
          "birthdays": [],
          "homework": [],
          "family_members": [],
          "weather": null,
          "finance_action": null,
          "unavailable": []
        }
        """
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            if url.path.hasSuffix("/briefing/dashboard") {
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(dashboardJSON.utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"Unavailable"}"#.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-03T12:00:00Z")! }
        )

        await viewModel.loadDashboard()

        XCTAssertNil(viewModel.fitnessTodayCard)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.dailyBriefing?.date, "2026-08-03")
    }

    @MainActor
    func testDashboardPreservesKnownEventsAndTasksWhenThoseFeedsAreUnavailable() async throws {
        let dashboardJSON = """
        {
          "generated_at": "2026-08-03T06:00:00Z",
          "date": "2026-08-03",
          "events": [],
          "tasks": [],
          "naps": [],
          "illnesses": [],
          "illness_readings": {},
          "routines": [],
          "meals": [],
          "dog": null,
          "coordination": null,
          "memories": [],
          "insights": [],
          "prep_suggestions": [],
          "medicine": [],
          "birthdays": [],
          "homework": [],
          "family_members": [],
          "weather": null,
          "finance_action": null,
          "unavailable": ["events", "tasks"]
        }
        """
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(dashboardJSON.utf8)
            )
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try decoder.decode(CalendarEventDTO.self, from: Data("""
        {
          "id": "known-event",
          "title": "School run",
          "description": null,
          "start_time": "2026-08-03T07:30:00Z",
          "end_time": "2026-08-03T08:00:00Z",
          "all_day": false,
          "recurrence_rule": null,
          "location": null,
          "family_member_ids": [],
          "created_at": "2026-08-01T08:00:00Z",
          "updated_at": "2026-08-01T08:00:00Z",
          "created_by": "dom",
          "assigned_to": null
        }
        """.utf8))
        let task = try decoder.decode(TaskDTO.self, from: Data("""
        {
          "id": "known-task",
          "title": "Pack school bag",
          "description": null,
          "assigned_to": "dom",
          "due_date": "2026-08-03T08:00:00Z",
          "completed_at": null,
          "category": "school",
          "recurrence_rule": null,
          "priority": 2,
          "created_at": "2026-08-01T08:00:00Z",
          "updated_at": "2026-08-01T08:00:00Z",
          "created_by": "dom",
          "actionable_from": null,
          "assignees": [],
          "read_only": false
        }
        """.utf8))
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-03T12:00:00Z")! }
        )
        viewModel.todaysEvents = [event]
        viewModel.tasksDueToday = [task]
        viewModel.actionableTasks = [task]

        await viewModel.loadDashboard(fitnessEnabled: false)

        XCTAssertTrue(viewModel.eventsUnavailable)
        XCTAssertTrue(viewModel.tasksUnavailable)
        XCTAssertEqual(viewModel.todaysEvents.map(\.id), ["known-event"])
        XCTAssertEqual(viewModel.tasksDueToday.map(\.id), ["known-task"])
        XCTAssertEqual(viewModel.actionableTasks.map(\.id), ["known-task"])
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testDashboardPreservesIllnessAndNapContextButFailsClosedForMedicine() async {
        let firstJSON = """
        {
          "generated_at": "2026-08-03T06:00:00Z", "date": "2026-08-03",
          "events": [], "tasks": [],
          "naps": [{"id":"nap-1","child_id":"child-1","started_at":"2026-08-03T10:00:00Z","ended_at":null,"location":null,"notes":null,"sleep_type":"nap","duration_minutes":null,"created_at":"2026-08-03T10:00:00Z","updated_at":"2026-08-03T10:00:00Z","created_by":"dom"}],
          "illnesses": [{"id":"illness-1","child_id":"child-1","started_at":"2026-08-03T08:00:00Z","notes":"Resting"}],
          "illness_readings": {}, "routines": [], "meals": [], "dog": null,
          "coordination": null, "memories": [], "insights": [], "prep_suggestions": [],
          "medicine": [{"child_id":"child-1","child_name":"Child Two","medicine_name":"Calpol","next_safe_at":"2026-08-03T14:00:00Z","is_safe_now":false,"last_given_at":"2026-08-03T10:00:00Z"}],
          "birthdays": [], "homework": [], "family_members": [], "weather": null,
          "finance_action": null, "unavailable": []
        }
        """
        let failedRefreshJSON = """
        {
          "generated_at": "2026-08-03T06:05:00Z", "date": "2026-08-03",
          "events": [], "tasks": [], "naps": [], "illnesses": [],
          "illness_readings": {}, "routines": [], "meals": [], "dog": null,
          "coordination": null, "memories": [], "insights": [], "prep_suggestions": [],
          "medicine": [], "birthdays": [], "homework": [], "family_members": [],
          "weather": null, "finance_action": null,
          "unavailable": ["naps", "illnesses", "medicine"]
        }
        """
        let responseLock = NSLock()
        var requestCount = 0
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            let body = responseLock.withLock { () -> String in
                defer { requestCount += 1 }
                return requestCount == 0 ? firstJSON : failedRefreshJSON
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-03T12:00:00Z")! }
        )

        await viewModel.loadDashboard(fitnessEnabled: false)
        await viewModel.loadDashboard(fitnessEnabled: false)

        XCTAssertEqual(viewModel.activeNaps.map(\.id), ["nap-1"])
        XCTAssertEqual(viewModel.activeIllnesses.map(\.id), ["illness-1"])
        XCTAssertTrue(viewModel.medicineAttention.isEmpty)
        XCTAssertTrue(viewModel.unavailableFeeds.isSuperset(
            of: Set(["naps", "illnesses", "medicine"])
        ))
    }

    @MainActor
    func testMidnightTransportFailureCannotCarryAnOldActiveNapIntoToday() async {
        let dashboardJSON = """
        {
          "generated_at":"2026-08-03T22:30:00Z","date":"2026-08-03",
          "events":[],"tasks":[],
          "naps":[{"id":"nap-before-midnight","child_id":"child-1","started_at":"2026-08-03T22:00:00Z","ended_at":null,"location":null,"notes":null,"sleep_type":"bedtime","duration_minutes":null,"created_at":"2026-08-03T22:00:00Z","updated_at":"2026-08-03T22:00:00Z","created_by":"dom"}],
          "illnesses":[],"illness_readings":{},"routines":[],"meals":[],"dog":null,
          "coordination":null,"memories":[],"insights":[],"prep_suggestions":[],
          "medicine":[],"birthdays":[],"homework":[],"family_members":[],"weather":null,
          "finance_action":null,"unavailable":[]
        }
        """
        let responseLock = NSLock()
        var requestCount = 0
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            let shouldFail = responseLock.withLock { () -> Bool in
                defer { requestCount += 1 }
                return requestCount > 0
            }
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(dashboardJSON.utf8)
            )
        }
        var clock = ISODateParser.parse("2026-08-03T22:45:00Z")!
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { clock }
        )

        await viewModel.loadDashboard(fitnessEnabled: false)
        XCTAssertEqual(viewModel.activeNaps.map(\.id), ["nap-before-midnight"])

        clock = ISODateParser.parse("2026-08-04T08:00:00Z")!
        await viewModel.loadDashboard(fitnessEnabled: false)

        XCTAssertTrue(viewModel.activeNaps.isEmpty)
        XCTAssertTrue(viewModel.unavailableFeeds.contains("naps"))
    }

    @MainActor
    func testSameDayOfflineFallbackClearsMedicineAndActiveNapClaims() async {
        let dashboardJSON = """
        {
          "generated_at":"2026-08-03T10:00:00Z","date":"2026-08-03",
          "events":[],"tasks":[],
          "naps":[{"id":"nap-1","child_id":"child-1","started_at":"2026-08-03T09:45:00Z","ended_at":null,"location":null,"notes":null,"sleep_type":"nap","duration_minutes":null,"created_at":"2026-08-03T09:45:00Z","updated_at":"2026-08-03T09:45:00Z","created_by":"dom"}],
          "illnesses":[{"id":"illness-1","child_id":"child-1","started_at":"2026-08-02T08:00:00Z","notes":"Resting"}],
          "illness_readings":{},"routines":[],"meals":[],"dog":null,"coordination":null,
          "memories":[],"insights":[],"prep_suggestions":[],
          "medicine":[{"child_id":"child-1","child_name":"Child Two","medicine_name":"Calpol","next_safe_at":"2026-08-03T14:00:00Z","is_safe_now":false,"last_given_at":"2026-08-03T10:00:00Z"}],
          "birthdays":[],"homework":[],"family_members":[],"weather":null,
          "finance_action":null,"unavailable":[]
        }
        """
        let responseLock = NSLock()
        var requestCount = 0
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            let shouldFail = responseLock.withLock { () -> Bool in
                defer { requestCount += 1 }
                return requestCount > 0
            }
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(dashboardJSON.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-03T12:00:00Z")! }
        )

        await viewModel.loadDashboard(fitnessEnabled: false)
        XCTAssertEqual(viewModel.activeNaps.map(\.id), ["nap-1"])
        XCTAssertEqual(viewModel.medicineAttention.map(\.medicineName), ["Calpol"])

        await viewModel.loadDashboard(fitnessEnabled: false)

        XCTAssertTrue(viewModel.activeNaps.isEmpty)
        XCTAssertTrue(viewModel.medicineAttention.isEmpty)
        XCTAssertEqual(viewModel.activeIllnesses.map(\.id), ["illness-1"])
        XCTAssertTrue(viewModel.unavailableFeeds.isSuperset(of: Set(["naps", "medicine"])))
    }

    @MainActor
    func testPriorDayDashboardCannotClaimCalendarOrMedicineAsToday() async {
        let dashboardJSON = """
        {
          "generated_at": "2026-08-03T21:00:00Z", "date": "2026-08-03",
          "events": [{"id":"old-event","title":"Yesterday all day","description":null,"start_time":"2026-08-03","end_time":"2026-08-04","all_day":true,"recurrence_rule":null,"location":null,"family_member_ids":[],"created_at":"2026-08-01T08:00:00Z","updated_at":"2026-08-01T08:00:00Z","created_by":"dom","assigned_to":null}],
          "tasks": [{"id":"task-1","title":"Still needs doing","description":null,"assigned_to":"dom","due_date":"2026-08-03T08:00:00Z","completed_at":null,"category":"home","recurrence_rule":null,"priority":2,"created_at":"2026-08-01T08:00:00Z","updated_at":"2026-08-01T08:00:00Z","created_by":"dom","actionable_from":null,"assignees":[],"read_only":false}],
          "naps": [{"id":"old-nap","child_id":"child-1","started_at":"2026-08-03T20:00:00Z","ended_at":null,"location":null,"notes":null,"sleep_type":"bedtime","duration_minutes":null,"created_at":"2026-08-03T20:00:00Z","updated_at":"2026-08-03T20:00:00Z","created_by":"dom"}],
          "illnesses": [], "illness_readings": {}, "routines": [],
          "meals": [], "dog": null, "coordination": null, "memories": [],
          "insights": [], "prep_suggestions": [],
          "medicine": [{"child_id":"child-1","child_name":"Child Two","medicine_name":"Calpol","next_safe_at":"2026-08-03T22:00:00Z","is_safe_now":true,"last_given_at":"2026-08-03T18:00:00Z"}],
          "birthdays": [], "homework": [], "family_members": [], "weather": null,
          "finance_action": null, "unavailable": []
        }
        """
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(dashboardJSON.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-04T12:00:00Z")! }
        )

        await viewModel.loadDashboard(fitnessEnabled: false)

        XCTAssertTrue(viewModel.todaysEvents.isEmpty)
        XCTAssertTrue(viewModel.activeNaps.isEmpty)
        XCTAssertTrue(viewModel.medicineAttention.isEmpty)
        XCTAssertEqual(viewModel.actionableTasks.map(\.id), ["task-1"])
        XCTAssertTrue(viewModel.eventsUnavailable)
        XCTAssertTrue(viewModel.unavailableFeeds.contains("naps"))
        XCTAssertTrue(viewModel.unavailableFeeds.contains("medicine"))
    }

    @MainActor
    func testPriorDayDashboardClearsCivilDayCardsButKeepsDurableContextAvailable() async {
        let dashboardJSON = """
        {"generated_at":"2026-08-03T21:00:00Z","date":"2026-08-03","events":[],"tasks":[],"naps":[],"illnesses":[],"illness_readings":{},"routines":[],"meals":[],"dog":null,"coordination":null,"memories":[],"insights":[],"prep_suggestions":[],"medicine":[],"birthdays":[],"homework":[],"family_members":[],"weather":null,"finance_action":null,"facility_quick_fact":null,"unavailable":[]}
        """
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(dashboardJSON.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-04T12:00:00Z")! }
        )
        viewModel.activeRoutines = [ActiveRoutineDTO(
            routineItemId: "routine-1", personId: "child-1", personName: "Child One",
            name: "PE kit", color: "blue", date: "2026-08-03", timeOfDay: nil,
            location: nil, preparationNote: nil, prepTemplateId: nil,
            reminderMinutes: nil
        )]
        viewModel.mealPlans = [MealPlanDTO(
            id: "meal-plan-1", mealId: "meal-1", date: "2026-08-03",
            mealType: "dinner", mealName: "Yesterday pasta", notes: nil,
            tiredHousehold: false
        )]
        viewModel.tomorrowCard = TomorrowCardDTO(
            targetDate: "2026-08-04", visible: true, acknowledged: false,
            events: [], tasks: [], loadPrompt: nil
        )
        let oldFacilityDay = FacilityDaySummaryDTO(
            date: "2026-08-03", covered: true, familySwimming: [],
            laneSwimming: [], weightsRoom: [], poolClosed: false,
            weightsRoomStatus: "open", weightsRelevant: true
        )
        viewModel.facilityQuickFact = FacilityQuickFactDTO(
            provider: "school", sourceTitle: "Old timetable", sourceDocumentId: nil,
            currentFrom: "2026-08-01", currentTo: "2026-08-31", updateDue: false,
            today: oldFacilityDay, tomorrow: oldFacilityDay
        )
        viewModel.dailyBriefing = DailyBriefingDTO(
            date: "2026-08-03", generatedAt: "2026-08-03T21:00:00Z",
            calendarEvents: [], tasksDue: [],
            upcomingBirthdays: [BriefingBirthdayDTO(
                personName: "Yesterday birthday", dateOfBirth: nil,
                daysUntil: 0, turningAge: nil
            )],
            weather: BriefingWeatherDTO(
                description: "sunny", tempHigh: 22, tempLow: 14, rainChance: 0
            )
        )

        await viewModel.loadDashboard(fitnessEnabled: false)

        XCTAssertTrue(viewModel.activeRoutines.isEmpty)
        XCTAssertTrue(viewModel.mealPlans.isEmpty)
        XCTAssertNil(viewModel.tomorrowCard)
        XCTAssertNil(viewModel.facilityQuickFact)
        XCTAssertTrue(viewModel.dailyBriefing?.upcomingBirthdays.isEmpty == true)
        XCTAssertNil(viewModel.dailyBriefing?.weather)
    }

    @MainActor
    func testCurrentDashboardDropsEventsThatDoNotOverlapToday() async {
        let dashboardJSON = """
        {
          "generated_at": "2026-08-04T06:00:00Z", "date": "2026-08-04",
          "events": [
            {"id":"old-event","title":"Yesterday","description":null,"start_time":"2026-08-03","end_time":"2026-08-04","all_day":true,"recurrence_rule":null,"location":null,"family_member_ids":[],"created_at":"2026-08-01T08:00:00Z","updated_at":"2026-08-01T08:00:00Z","created_by":"dom","assigned_to":null},
            {"id":"today-event","title":"Today","description":null,"start_time":"2026-08-04T14:00:00Z","end_time":"2026-08-04T15:00:00Z","all_day":false,"recurrence_rule":null,"location":null,"family_member_ids":[],"created_at":"2026-08-01T08:00:00Z","updated_at":"2026-08-01T08:00:00Z","created_by":"dom","assigned_to":null}
          ],
          "tasks": [], "naps": [], "illnesses": [], "illness_readings": {},
          "routines": [], "meals": [], "dog": null, "coordination": null,
          "memories": [], "insights": [], "prep_suggestions": [], "medicine": [],
          "birthdays": [], "homework": [], "family_members": [], "weather": null,
          "finance_action": null, "unavailable": []
        }
        """
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(dashboardJSON.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-04T12:00:00Z")! }
        )

        await viewModel.loadDashboard(fitnessEnabled: false)

        XCTAssertEqual(viewModel.todaysEvents.map(\.id), ["today-event"])
        XCTAssertFalse(viewModel.eventsUnavailable)
    }

    @MainActor
    func testPriorDayFitnessCardFallsBackInsteadOfAppearingAsTodaysWorkout() async {
        let dashboardJSON = """
        {"generated_at":"2026-08-04T06:00:00Z","date":"2026-08-04","events":[],"tasks":[],"naps":[],"illnesses":[],"illness_readings":{},"routines":[],"meals":[],"dog":null,"coordination":null,"memories":[],"insights":[],"prep_suggestions":[],"medicine":[],"birthdays":[],"homework":[],"family_members":[],"weather":null,"finance_action":null,"unavailable":[]}
        """
        let oldFitnessJSON = """
        {"date":"2026-08-03","session":{"id":"old-plan","kind":"planned_session","title":"Yesterday run","sport_key":"running","status":"accepted","starts_at":"2026-08-03T07:00:00Z","scheduled_date":"2026-08-03","duration_minutes":30,"movable":true},"primary_action":{"kind":"open_session","label":"Open","destination":"plan","target_id":"old-plan"},"secondary_action":null}
        """
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            let body = url.path.hasSuffix("/briefing/dashboard") ? dashboardJSON : oldFitnessJSON
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [] },
            now: { ISODateParser.parse("2026-08-04T12:00:00Z")! }
        )

        await viewModel.loadDashboard()

        XCTAssertNil(viewModel.fitnessTodayCard)
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testDashboardUsesCachedActiveStrengthWorkoutWhenFitnessRequestFails() async throws {
        let fitnessRoot = try activateFitnessOwnerForDashboardTest()
        defer { deactivateFitnessOwnerForDashboardTest(at: fitnessRoot) }
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"Unavailable"}"#.utf8)
            )
        }
        let active = FitnessStrengthSession(
            id: "strength-active",
            title: "Evening strength",
            status: .active,
            startedAt: Date(),
            endedAt: nil,
            plannedSessionId: nil,
            readiness: nil,
            sessionRPE: nil,
            performance: nil,
            note: nil,
            revision: 1,
            updatedAt: Date()
        )
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { active },
            loadCachedPlannedSessions: { [] }
        )

        await viewModel.loadDashboard()

        XCTAssertEqual(viewModel.fitnessTodayCard?.session?.id, "strength-active")
        XCTAssertEqual(viewModel.fitnessTodayCard?.primaryAction?.label, "Resume")
        XCTAssertEqual(viewModel.fitnessTodayCard?.primaryAction?.targetId, "strength-active")
    }

    @MainActor
    func testDashboardOffersCachedBlankStrengthStartWhenTodayIsEmpty() async throws {
        let fitnessRoot = try activateFitnessOwnerForDashboardTest()
        defer { deactivateFitnessOwnerForDashboardTest(at: fitnessRoot) }
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(
                    url:url,
                    statusCode:503,
                    httpVersion:nil,
                    headerFields:["Content-Type":"application/json"]
                )!,
                Data(#"{"detail":"Unavailable"}"#.utf8)
            )
        }
        let viewModel=DashboardViewModel(
            apiClient:client,
            loadCachedActiveWorkout:{ nil },
            loadCachedPlannedSessions:{ [] },
            now:{ ISODateParser.parse("2026-08-03T12:00:00Z")! }
        )

        await viewModel.loadDashboard()

        XCTAssertEqual(viewModel.fitnessTodayCard?.date,"2026-08-03")
        XCTAssertEqual(viewModel.fitnessTodayCard?.primaryAction?.kind,"start_strength")
        XCTAssertEqual(viewModel.fitnessTodayCard?.primaryAction?.label,"Start workout")
        XCTAssertNil(viewModel.fitnessTodayCard?.session)
    }

    @MainActor
    func testDashboardCachedNonStrengthPlanUsesOpenAction() async throws {
        let fitnessRoot = try activateFitnessOwnerForDashboardTest()
        defer { deactivateFitnessOwnerForDashboardTest(at: fitnessRoot) }
        let client = makeStubbedClient { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"Unavailable"}"#.utf8)
            )
        }
        let plan = FitnessPlannedSession(
            id: "run-plan",
            title: "Easy run",
            plannedFor: Date(),
            exerciseIds: [],
            isCompleted: false,
            revision: 1,
            updatedAt: Date(),
            status: "accepted",
            sportKey: "running",
            movable: true
        )
        let viewModel = DashboardViewModel(
            apiClient: client,
            loadCachedActiveWorkout: { nil },
            loadCachedPlannedSessions: { [plan] }
        )

        await viewModel.loadDashboard()

        XCTAssertEqual(viewModel.fitnessTodayCard?.primaryAction?.kind, "open_session")
        XCTAssertEqual(viewModel.fitnessTodayCard?.primaryAction?.label, "Open")
        XCTAssertEqual(viewModel.fitnessTodayCard?.secondaryAction?.label, "Move")
    }

    @MainActor
    func testAppStateCarriesExactFitnessDestinationAndTarget() {
        let appState = AppState()
        appState.applyFitnessWorkspacePreference(.init(enabled:true,pinned:true))

        appState.openFitness(
            destination: .progress,
            targetId: "activity-exact",
            actionKind: "open_activity"
        )

        XCTAssertEqual(appState.selectedTab, .fitness)
        XCTAssertNil(appState.familyRoute)
        XCTAssertEqual(appState.selectedFitnessDestination, .activities)
        XCTAssertEqual(appState.fitnessDeepLinkIntent?.destination, .activities)
        XCTAssertEqual(appState.fitnessDeepLinkIntent?.targetId, "activity-exact")
        XCTAssertEqual(appState.fitnessDeepLinkIntent?.actionKind, "open_activity")
    }
}

final class DashboardLoadPresentationTests: XCTestCase {
    func testFirstFrameIsLoadingInsteadOfClaimingTheDayIsEmpty() {
        XCTAssertEqual(
            DashboardLoadPresentation.resolve(hasLoadedBriefing: false, hasError: false),
            .loading
        )
    }

    func testFirstLoadFailureSuppressesDishonestEmptyStates() {
        XCTAssertEqual(
            DashboardLoadPresentation.resolve(hasLoadedBriefing: false, hasError: true),
            .unavailable
        )
    }

    func testSuccessfulEmptyDashboardCanShowRealEmptyActions() {
        XCTAssertEqual(
            DashboardLoadPresentation.resolve(hasLoadedBriefing: true, hasError: false),
            .ready
        )
    }

    func testRefreshFailureKeepsPreviouslyLoadedDayUseful() {
        XCTAssertEqual(
            DashboardLoadPresentation.resolve(hasLoadedBriefing: true, hasError: true),
            .ready
        )
    }
}
