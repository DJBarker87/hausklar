import XCTest
@testable import HausKlar

final class TodayQuickEntryTests: XCTestCase {
    private var directory: URL!
    private var database: FitnessDatabase!
    private var nutritionRepository: FitnessNutritionRepository!
    private var fitnessRepository: FitnessRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayQuickEntryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = FitnessDatabase()
        try database.activateForTesting(
            identity: "family-a:user-a",
            storeURL: directory.appendingPathComponent("fitness.sqlite")
        )
        nutritionRepository = FitnessNutritionRepository(
            database: database,
            deviceId: "today-nutrition-test"
        )
        fitnessRepository = FitnessRepository(
            database: database,
            deviceId: "today-fitness-test"
        )
    }

    override func tearDownWithError() throws {
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMealPromptKeepsClosestStartedMealActionableInsideNinetyMinutes() throws {
        let calendar = Self.utcCalendar
        let preferences = FitnessQuickEntryPreferences(
            mealTimes: FitnessQuickEntryMealTimes(
                breakfast: "08:00",
                lunch: "09:30",
                dinner: "18:30"
            )
        )

        // Logging one item starts a meal; it must not make the contextual
        // shortcut disappear when another item still needs adding.
        let beforeLunch = Self.date(hour: 9, minute: 20, calendar: calendar)
        let started = FitnessQuickEntryPolicy.mealPrompt(
            at: beforeLunch,
            preferences: preferences,
            loggedMeals: [.lunch],
            calendar: calendar
        )
        XCTAssertEqual(started?.meal, .lunch)
        XCTAssertEqual(started?.hasEntries, true)
        let normalLunch = Self.date(hour: 12, minute: 30, calendar: calendar)
        XCTAssertNil(FitnessQuickEntryPolicy.mealPrompt(
            at: normalLunch,
            preferences: .defaults,
            loggedMeals: [.lunch],
            completedMeals: [.lunch],
            calendar: calendar
        ))

        let breakfastBoundary = Self.date(hour: 9, minute: 30, calendar: calendar)
        let standard = FitnessQuickEntryPreferences.defaults
        let unstarted = FitnessQuickEntryPolicy.mealPrompt(
                at: breakfastBoundary,
                preferences: standard,
                loggedMeals: [],
                calendar: calendar
        )
        XCTAssertEqual(unstarted?.meal, .breakfast)
        XCTAssertEqual(unstarted?.hasEntries, false)
        XCTAssertNil(
            FitnessQuickEntryPolicy.mealPrompt(
                at: Self.date(hour: 9, minute: 31, calendar: calendar),
                preferences: standard,
                loggedMeals: [],
                calendar: calendar
            )
        )
        XCTAssertNil(FitnessQuickEntryPolicy.minuteOfDay(from: "8:00"))
        XCTAssertNil(FitnessQuickEntryPolicy.minuteOfDay(from: "24:00"))
    }

    func testTodayNutritionProgressUsesExplicitDayCompletionForCalories() throws {
        XCTAssertFalse(
            TodayNutritionProgressPolicy.dayIsComplete(
                completedMeals: [.breakfast, .lunch]
            )
        )
        XCTAssertTrue(
            TodayNutritionProgressPolicy.dayIsComplete(
                completedMeals: [.breakfast, .lunch, .dinner, .snack]
            )
        )

        let stillEating = try XCTUnwrap(
            TodayNutritionProgressPolicy.progress(
                for: .calories,
                value: 1_600,
                target: 2_000,
                valueIsComplete: true,
                hasEntries: true,
                dayIsComplete: false
            )
        )
        XCTAssertEqual(stillEating.fraction, 0.8, accuracy: 0.001)
        XCTAssertFalse(stillEating.reachedGoal)

        let successfulDay = try XCTUnwrap(
            TodayNutritionProgressPolicy.progress(
                for: .calories,
                value: 1_900,
                target: 2_000,
                valueIsComplete: true,
                hasEntries: true,
                dayIsComplete: true
            )
        )
        XCTAssertTrue(successfulDay.reachedGoal)

        let unknownCalories = try XCTUnwrap(
            TodayNutritionProgressPolicy.progress(
                for: .calories,
                value: 1_900,
                target: 2_000,
                valueIsComplete: false,
                hasEntries: true,
                dayIsComplete: true
            )
        )
        XCTAssertFalse(unknownCalories.reachedGoal)

        let overTarget = try XCTUnwrap(
            TodayNutritionProgressPolicy.progress(
                for: .calories,
                value: 2_100,
                target: 2_000,
                valueIsComplete: true,
                hasEntries: true,
                dayIsComplete: true
            )
        )
        XCTAssertEqual(overTarget.fraction, 1, accuracy: 0.001)
        XCTAssertFalse(overTarget.reachedGoal)
    }

    func testTodayProteinProgressCelebratesAsSoonAsKnownTotalReachesTarget() throws {
        let progress = try XCTUnwrap(
            TodayNutritionProgressPolicy.progress(
                for: .protein,
                value: 125,
                target: 120,
                valueIsComplete: false,
                hasEntries: true,
                dayIsComplete: false
            )
        )

        XCTAssertEqual(progress.fraction, 1, accuracy: 0.001)
        XCTAssertTrue(progress.reachedGoal)
        XCTAssertNil(
            TodayNutritionProgressPolicy.progress(
                for: .protein,
                value: 125,
                target: nil,
                valueIsComplete: true,
                hasEntries: true,
                dayIsComplete: true
            )
        )
    }

    func testStrengthAvailabilityDecodesProviderAndPerClassBookingLink() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let availability = try decoder.decode(
            FitnessStrengthAvailability.self,
            from: Data(Self.availabilityJSON.utf8)
        )

        XCTAssertEqual(availability.provider, "vi_training")
        XCTAssertEqual(availability.displayTitle, "Vi timetable")
        let window = try XCTUnwrap(availability.days.first?.windows.first)
        XCTAssertEqual(window.label, "Strength Circuit")
        XCTAssertEqual(
            SafeExternalURL.web(window.bookingUrl)?.absoluteString,
            "https://vi.example.test/book/strength-circuit"
        )

        let neutral = FitnessStrengthAvailability(
            provider: "another_provider",
            sourceTitle: "  ",
            sourceUrl: nil,
            unavailableReason: nil,
            days: []
        )
        XCTAssertEqual(neutral.displayTitle, "Strength timetable")

        let unsafe = FitnessStrengthAvailabilityWindow(
            start: "19:00",
            end: "20:00",
            label: "Unsafe",
            bookingUrl: "javascript:alert(1)"
        )
        XCTAssertNil(SafeExternalURL.web(unsafe.bookingUrl))
    }

    func testViScheduleDecodesEveryPublicClassAndServerRelevance() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let schedule = try decoder.decode(
            FitnessViSchedule.self,
            from: Data(Self.viScheduleJSON.utf8)
        )

        XCTAssertTrue(schedule.relevant)
        XCTAssertEqual(schedule.provider, "vi_training")
        let classes = try XCTUnwrap(schedule.days.first?.classes)
        XCTAssertEqual(classes.map(\.label), ["Strength Circuit", "Run community"])
        XCTAssertEqual(classes.map(\.classification), [.strength, .run])
        XCTAssertEqual(classes.last?.displayTime, "08:30–09:20")
    }

    func testServiceUsesExactPreferenceAndAvailabilityContractsAndFallsBackToCache() async throws {
        let recorder = TodayQuickEntryRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/fitness/quick-entry-preferences"):
                return (response, Data(Self.preferencesJSON.utf8))
            case ("PATCH", "/api/fitness/quick-entry-preferences"):
                return (
                    response,
                    Data(#"{"meal_times":{"breakfast":"07:45","lunch":"12:15","dinner":"18:45"}}"#.utf8)
                )
            case ("GET", "/api/fitness/strength-availability"):
                return (response, Data(Self.availabilityJSON.utf8))
            case ("GET", "/api/fitness/vi-schedule"):
                return (response, Data(Self.viScheduleJSON.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(url.path)")
                return (response, Data(#"{"detail":"unexpected"}"#.utf8))
            }
        }
        let client = Self.makeClient()
        let service = FitnessNutritionService(
            repository: nutritionRepository,
            apiClient: client,
            database: database
        )
        await service.activate(identity: "family-a:user-a")
        defer {
            client.clearSession()
            Task { await service.suspend() }
        }

        let loaded = try await service.quickEntryPreferences(refresh: true)
        XCTAssertFalse(loaded.isFromCache)
        XCTAssertEqual(loaded.value.mealTimes.breakfast, "08:00")

        let saved = try await service.updateQuickEntryPreferences(
            FitnessQuickEntryMealTimes(
                breakfast: "07:45",
                lunch: "12:15",
                dinner: "18:45"
            )
        )
        XCTAssertEqual(saved.mealTimes.dinner, "18:45")

        let availability = try await service.strengthAvailability(
            start: "2026-08-12",
            end: "2026-08-12",
            refresh: true
        )
        XCTAssertEqual(availability.value.provider, "vi_training")
        let availabilityRequest = try XCTUnwrap(
            recorder.requests.first { $0.url?.path.hasSuffix("strength-availability") == true }
        )
        let query = URLComponents(
            url: try XCTUnwrap(availabilityRequest.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "start" })?.value, "2026-08-12")
        XCTAssertEqual(query?.first(where: { $0.name == "end" })?.value, "2026-08-12")

        let vi = try await service.viSchedule(
            start: "2026-08-12",
            end: "2026-08-12",
            refresh: true
        )
        XCTAssertFalse(vi.isFromCache)
        XCTAssertEqual(vi.value.days.first?.classes.count, 2)
        let viRequest = try XCTUnwrap(
            recorder.requests.first { $0.url?.path.hasSuffix("vi-schedule") == true }
        )
        let viQuery = URLComponents(
            url: try XCTUnwrap(viRequest.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(viQuery?.first(where: { $0.name == "start" })?.value, "2026-08-12")
        XCTAssertEqual(viQuery?.first(where: { $0.name == "end" })?.value, "2026-08-12")

        let patch = try XCTUnwrap(
            recorder.requests.first {
                $0.httpMethod == "PATCH"
                    && $0.url?.path.hasSuffix("quick-entry-preferences") == true
            }
        )
        let patchBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(patch.httpBody))
                as? [String: Any]
        )
        let mealTimes = try XCTUnwrap(patchBody["meal_times"] as? [String: String])
        XCTAssertEqual(mealTimes["breakfast"], "07:45")
        XCTAssertEqual(mealTimes["lunch"], "12:15")
        XCTAssertEqual(mealTimes["dinner"], "18:45")

        APIClientStubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        let cached = try await service.quickEntryPreferences(refresh: true)
        XCTAssertTrue(cached.isFromCache)
        XCTAssertEqual(cached.value.mealTimes.breakfast, "07:45")
        let cachedVi = try await service.viSchedule(
            start: "2026-08-12",
            end: "2026-08-12",
            refresh: true
        )
        XCTAssertTrue(cachedVi.isFromCache)
        XCTAssertEqual(cachedVi.value.days.first?.classes.last?.classification, .run)
    }

    func testServiceSearchesFoodsAndCompletesMealUsingExactContracts() async throws {
        let recorder = TodayQuickEntryRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let status = request.httpMethod == "POST" ? 201 : 200
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/fitness/food-lookup/search"):
                return (response, Data(Self.foodSearchJSON.utf8))
            case ("GET", "/api/fitness/nutrition/meal-completions"):
                return (response, Data("[\(Self.mealCompletionJSON)]".utf8))
            case ("POST", "/api/fitness/nutrition/meal-completions"):
                return (response, Data(Self.mealCompletionJSON.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(url.path)")
                return (response, Data(#"{"detail":"unexpected"}"#.utf8))
            }
        }
        let client = Self.makeClient()
        let service = FitnessNutritionService(
            repository: nutritionRepository,
            apiClient: client,
            database: database
        )
        await service.activate(identity: "family-a:user-a")
        defer {
            client.clearSession()
            Task { await service.suspend() }
        }

        let results = try await service.foodSearch("porridge oats")
        XCTAssertEqual(results.first?.name, "Porridge oats")
        XCTAssertEqual(results.first?.referenceUnit, "g")
        let searchRequest = try XCTUnwrap(
            recorder.requests.first { $0.url?.path.hasSuffix("food-lookup/search") == true }
        )
        let searchQuery = URLComponents(
            url: try XCTUnwrap(searchRequest.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(searchQuery?.first(where: { $0.name == "q" })?.value, "porridge oats")

        let existing = try await service.mealCompletions(on: "2026-08-12")
        XCTAssertEqual(existing.map(\.meal), [.lunch])
        let completion = try await service.completeMeal(on: "2026-08-12", meal: .lunch)
        XCTAssertEqual(completion.nutritionDate, "2026-08-12")
        XCTAssertEqual(completion.meal, .lunch)

        let completionRequests = recorder.requests.filter {
            $0.url?.path == "/api/fitness/nutrition/meal-completions"
        }
        let getQuery = URLComponents(
            url: try XCTUnwrap(completionRequests.first?.url),
            resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(getQuery?.first(where: { $0.name == "date" })?.value, "2026-08-12")
        let post = try XCTUnwrap(completionRequests.first { $0.httpMethod == "POST" })
        let body = try Self.jsonBody(post)
        XCTAssertEqual(body["nutrition_date"] as? String, "2026-08-12")
        XCTAssertEqual(body["meal_key"] as? String, "lunch")
        let operationID = try XCTUnwrap(body["id"] as? String)
        XCTAssertEqual(post.value(forHTTPHeaderField: "X-HausKlar-Operation-ID"), operationID)
    }

    @MainActor
    func testSuccessfulMealCompletionRemovesTodayPrompt() async throws {
        APIClientStubURLProtocol.install { request in
            let url = try XCTUnwrap(request.url)
            let status = request.httpMethod == "POST" ? 201 : 200
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch (request.httpMethod, url.path) {
            case ("GET", "/api/fitness/quick-entry-preferences"):
                return (response, Data(Self.preferencesJSON.utf8))
            case ("GET", "/api/fitness/nutrition/meal-completions"):
                return (response, Data("[]".utf8))
            case ("POST", "/api/fitness/nutrition/meal-completions"):
                return (response, Data(Self.mealCompletionJSON.utf8))
            case ("GET", "/api/fitness/strength-availability"):
                return (response, Data(Self.availabilityJSON.utf8))
            case ("GET", "/api/fitness/vi-schedule"):
                return (response, Data(Self.viScheduleJSON.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(url.path)")
                return (response, Data(#"{"detail":"unexpected"}"#.utf8))
            }
        }
        let client = Self.makeClient()
        let service = FitnessNutritionService(
            repository: nutritionRepository,
            apiClient: client,
            database: database
        )
        await service.activate(identity: "family-a:user-a")
        defer {
            client.clearSession()
            Task { await service.suspend() }
        }
        let now = Self.date(hour: 12, minute: 30, calendar: Self.utcCalendar)
        let viewModel = TodayQuickEntryViewModel(
            nutritionService: service,
            nutritionRepository: nutritionRepository,
            fitnessRepository: fitnessRepository,
            database: database,
            apiClient: client,
            now: { now }
        )

        await viewModel.load(refresh: true)
        XCTAssertEqual(viewModel.mealPrompt?.meal, .lunch)

        let completed = await viewModel.completeMeal(.lunch)
        XCTAssertTrue(completed)
        XCTAssertNil(viewModel.mealPrompt)
        XCTAssertTrue(viewModel.completedMeals.contains(.lunch))
    }

    @MainActor
    func testQuickExerciseCreatesAnExactPrivateOfflinePlan() async throws {
        let client = Self.makeClient()
        defer { client.clearSession() }
        let service = FitnessNutritionService(
            repository: nutritionRepository,
            apiClient: client,
            database: database
        )
        let start = Date(timeIntervalSince1970: 1_786_544_400)
        let viewModel = TodayQuickEntryViewModel(
            nutritionService: service,
            nutritionRepository: nutritionRepository,
            fitnessRepository: fitnessRepository,
            database: database,
            apiClient: client,
            now: { start }
        )

        let didAdd = await viewModel.addExercise(kind: .run, start: start)
        XCTAssertTrue(didAdd)
        let plans = try await fitnessRepository.plannedSessions()
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.sportKey, "running")
        XCTAssertEqual(plan.title, "Run")
        XCTAssertEqual(plan.scheduledStart, start)
        XCTAssertEqual(plan.status, "accepted")
        XCTAssertEqual(plan.visibility, "private")
        XCTAssertFalse(plan.movable)
        XCTAssertNil(plan.expectedDurationSeconds)
        XCTAssertNil(plan.expectedDistanceMetres)

        let mutations = try await fitnessRepository.pendingMutations()
        let mutation = try XCTUnwrap(
            mutations.first {
                $0.entityType == FitnessEntityType.plannedSession.rawValue
                    && $0.entityId == plan.id
            }
        )
        XCTAssertEqual(mutation.payload["sport_key"]?.stringValue, "running")
        XCTAssertEqual(mutation.payload["status"]?.stringValue, "accepted")
        XCTAssertEqual(mutation.payload["visibility"]?.stringValue, "private")
        XCTAssertEqual(mutation.payload["scheduled_start_utc"]?.stringValue, FitnessDatabase.dateString(start))
    }

    @MainActor
    func testViBookingRetryRetainsOperationIDAndSendsExactClassWindow() async throws {
        let recorder = TodayQuickEntryRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            if request.httpMethod == "POST", url.path == "/api/fitness/vi-bookings" {
                if recorder.bookingAttemptCount == 1 {
                    throw URLError(.notConnectedToInternet)
                }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (
                    response,
                    Data(#"{"status":"booked","event_id":"event-1","title":"Run community","start_time":"2026-08-12T08:30:00+01:00","end_time":"2026-08-12T09:20:00+01:00","location":"Vi Training","classification":"run"}"#.utf8)
                )
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            switch url.path {
            case "/api/fitness/quick-entry-preferences":
                return (response, Data(Self.preferencesJSON.utf8))
            case "/api/fitness/nutrition/meal-completions":
                return (response, Data("[]".utf8))
            case "/api/fitness/strength-availability":
                return (response, Data(Self.availabilityJSON.utf8))
            case "/api/fitness/vi-schedule":
                return (response, Data(Self.viScheduleJSON.utf8))
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(url.path)")
                return (response, Data(#"{"detail":"unexpected"}"#.utf8))
            }
        }
        let client = Self.makeClient()
        let service = FitnessNutritionService(
            repository: nutritionRepository,
            apiClient: client,
            database: database
        )
        await service.activate(identity: "family-a:user-a")
        defer {
            client.clearSession()
            Task { await service.suspend() }
        }
        let now = Self.date(hour: 14, minute: 0, calendar: Self.utcCalendar)
        let viewModel = TodayQuickEntryViewModel(
            nutritionService: service,
            nutritionRepository: nutritionRepository,
            fitnessRepository: fitnessRepository,
            database: database,
            apiClient: client,
            now: { now }
        )
        await viewModel.load(refresh: true)
        XCTAssertEqual(viewModel.strengthAvailability?.provider, "vi_training")
        XCTAssertEqual(
            viewModel.strengthAvailability?.days.first?.windows.first?.label,
            "Strength Circuit"
        )
        let day = try XCTUnwrap(viewModel.viSchedule?.days.first)
        let entry = try XCTUnwrap(day.classes.last)

        let offlineBooking = await viewModel.bookViClass(
            day: day,
            entry: entry,
            online: false
        )
        XCTAssertFalse(offlineBooking)
        XCTAssertEqual(recorder.bookingAttemptCount, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Reconnect to confirm this Vi booking in HausKlar."
        )

        let firstBooking = await viewModel.bookViClass(day: day, entry: entry)
        XCTAssertFalse(firstBooking)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Reconnect to confirm this Vi booking in HausKlar."
        )
        let retriedBooking = await viewModel.bookViClass(day: day, entry: entry)
        XCTAssertTrue(retriedBooking)

        let posts = recorder.requests.filter {
            $0.httpMethod == "POST" && $0.url?.path == "/api/fitness/vi-bookings"
        }
        XCTAssertEqual(posts.count, 2)
        let first = try Self.jsonBody(posts[0])
        let second = try Self.jsonBody(posts[1])
        let operationID = try XCTUnwrap(first["id"] as? String)
        XCTAssertNotNil(UUID(uuidString: operationID))
        XCTAssertEqual(second["id"] as? String, operationID)
        XCTAssertEqual(second["client_timestamp"] as? String, first["client_timestamp"] as? String)
        XCTAssertEqual(second["date"] as? String, "2026-08-12")
        XCTAssertEqual(second["start"] as? String, "08:30")
        XCTAssertEqual(second["end"] as? String, "09:20")
        XCTAssertEqual(second["label"] as? String, "Run community")
        XCTAssertEqual(second["classification"] as? String, "run")
        XCTAssertEqual(second["provider"] as? String, "vi_training")
        XCTAssertEqual(second["client_id"] as? String, Self.clientID)
        XCTAssertEqual(posts[0].value(forHTTPHeaderField: "X-HausKlar-Operation-ID"), operationID)
        XCTAssertEqual(posts[1].value(forHTTPHeaderField: "X-HausKlar-Operation-ID"), operationID)
    }

    private static let clientID = "00000000-0000-4000-8000-000000000001"

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: 2026,
                month: 8,
                day: 12,
                hour: hour,
                minute: minute
            )
        )!
    }

    private static func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { clientID }
        )
        client.baseURL = "https://today-quick-entry-\(UUID().uuidString).example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        return client
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
    }

    private static let preferencesJSON =
        #"{"meal_times":{"breakfast":"08:00","lunch":"12:30","dinner":"18:30"}}"#

    private static let availabilityJSON =
        #"{"provider":"vi_training","source_title":"Vi timetable","source_url":"https://vi.example.test/classes","unavailable_reason":null,"days":[{"date":"2026-08-12","covered":true,"windows":[{"start":"18:00","end":"19:00","label":"Strength Circuit","booking_url":"https://vi.example.test/book/strength-circuit"}]}]}"#

    private static let viScheduleJSON =
        #"{"relevant":true,"provider":"vi_training","source_title":"Vi timetable","source_url":"https://vi.example.test/classes","unavailable_reason":null,"days":[{"date":"2026-08-12","covered":true,"classes":[{"start":"18:00","end":"19:00","label":"Strength Circuit","classification":"strength","booking_url":"https://vi.example.test/book/strength-circuit"},{"start":"08:30","end":"09:20","label":"Run community","classification":"run","booking_url":"https://vi.example.test/book/run-community"}]}]}"#

    private static let foodSearchJSON =
        #"[{"barcode":"5+000000000050","name":"Porridge oats","brand":"Test Mill","reference_amount":100,"reference_unit":"g","nutrients":{"calories_kcal":370,"protein_g":12,"carbohydrate_g":60,"sugars_g":1,"fat_g":8,"saturated_fat_g":1.5,"fibre_g":9,"salt_g":0.01,"sodium_mg":4,"micronutrients":{}},"serving":null,"source":"open_food_facts","source_url":"https://world.openfoodfacts.org/product/5+000000000050","warnings":[],"needs_review":true}]"#

    private static let mealCompletionJSON =
        #"{"id":"00000000-0000-4000-8000-000000000099","nutrition_date":"2026-08-12","meal_key":"lunch","completed_at":"2026-08-12T12:30:00Z","revision":1}"#
}

private final class TodayQuickEntryRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    var bookingAttemptCount: Int {
        lock.withLock {
            storage.filter {
                $0.httpMethod == "POST"
                    && $0.url?.path == "/api/fitness/vi-bookings"
            }.count
        }
    }

    func append(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil,
           let stream = captured.httpBodyStream,
           let body = Self.read(stream) {
            captured.httpBody = body
        }
        lock.withLock { storage.append(captured) }
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
