import XCTest
import UIKit
@testable import HausKlar

final class FitnessShellNavigationTests: XCTestCase {
    func testCanonicalPrimaryNavigationPrioritisesReviewFoodAndTraining() {
        XCTAssertEqual(
            FitnessDeepLinkDestination.primaryNavigation,
            [.progress, .log, .plan, .overview]
        )
        XCTAssertEqual(FitnessDeepLinkDestination.progress.title,"Review")
        XCTAssertEqual(FitnessDeepLinkDestination.log.title,"Food")
        XCTAssertEqual(FitnessDeepLinkDestination.plan.title,"Train")
        XCTAssertEqual(FitnessDeepLinkDestination.overview.title,"More")
    }

    func testPrimaryNavigationFitsAnIPhoneWithoutTruncatingReview() {
        XCTAssertLessThanOrEqual(
            FitnessPrimaryNavigationLayout.minimumRailWidth(
                itemCount: FitnessDeepLinkDestination.primaryNavigation.count
            ),
            393
        )
        let caption = UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .semibold
        )
        let reviewWidth = ("Review" as NSString).size(
            withAttributes: [.font: caption]
        ).width
        XCTAssertLessThanOrEqual(
            reviewWidth,
            FitnessPrimaryNavigationLayout.minimumItemWidth
        )
    }

    func testLegacyOverviewDataIsNotFetchedByAnyPrimaryDestination() {
        for destination in [
            FitnessDeepLinkDestination.overview, .activities, .log, .plan, .progress, .coach,
        ] {
            XCTAssertFalse(
                FitnessShellLoadPolicy.shouldLoadOverview(for:destination),
                "\(destination.rawValue) must not fetch the retired Overview feed"
            )
        }
    }

    func testOnboardingMustResolveAndDismissBeforeDestinationMounts() {
        XCTAssertFalse(
            FitnessShellLoadPolicy.shouldMountDestination(
                onboardingResolved:false,onboardingStatus:nil
            )
        )
        XCTAssertFalse(
            FitnessShellLoadPolicy.shouldMountDestination(
                onboardingResolved:true,onboardingStatus:.draft
            ),
            "A new adult must not load a destination underneath setup"
        )
        XCTAssertTrue(
            FitnessShellLoadPolicy.shouldMountDestination(
                onboardingResolved:true,onboardingStatus:.skipped
            )
        )
        XCTAssertTrue(
            FitnessShellLoadPolicy.shouldMountDestination(
                onboardingResolved:true,onboardingStatus:.complete
            )
        )
        XCTAssertTrue(
            FitnessShellLoadPolicy.shouldMountDestination(
                onboardingResolved:true,onboardingStatus:nil
            ),
            "A quiet onboarding fetch failure must not block established Fitness use"
        )
    }

    func testPlanSelectsOnlyTheNextAcceptedStartableSession() throws {
        let now=Date()
        let proposed=plan(id:"proposal",status:"proposed",date:now.addingTimeInterval(60))
        let later=plan(id:"later",status:"accepted",date:now.addingTimeInterval(7_200))
        let next=plan(id:"next",status:"scheduled",date:now.addingTimeInterval(3_600))
        let completed=plan(id:"done",status:"accepted",date:now,isCompleted:true)

        XCTAssertEqual(
            FitnessPlanExperiencePolicy.nextSession(in:[proposed,later,next,completed])?.id,
            "next"
        )
        XCTAssertEqual(FitnessPlanExperiencePolicy.week(containing:now).count,7)
    }

    func testProgressHomeLoadsReviewActivityHistoryChartsAndWeight() {
        XCTAssertEqual(
            FitnessProgressLoadPolicy.homeRequests(for:.home),
            ["weekly-review","activity-history","progress-charts","body-measurements"]
        )
        for detail in [
            FitnessProgressLoadArea.strength,.body,.recovery,.insights,
        ] {
            XCTAssertTrue(FitnessProgressLoadPolicy.homeRequests(for:detail).isEmpty)
        }
    }

    func testProgressTrendRequestsTheExactFourWeekWindow() throws {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=try XCTUnwrap(TimeZone(identifier:"Europe/Berlin"))
        let formatter=ISO8601DateFormatter()
        let sunday=try XCTUnwrap(formatter.date(from:"2026-08-09T12:00:00Z"))

        let filter=FitnessProgressLoadPolicy.fourWeekActivityFilter(
            for:sunday,calendar:calendar
        )

        XCTAssertEqual(filter.dateFrom,"2026-07-13")
        XCTAssertEqual(filter.dateTo,"2026-08-09")
    }

    func testCurrentWeekStartsOnMondayInBerlin() throws {
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=try XCTUnwrap(TimeZone(identifier:"Europe/Berlin"))
        let formatter=ISO8601DateFormatter()
        let sunday=try XCTUnwrap(formatter.date(from:"2026-08-09T12:00:00Z"))
        let monday=FitnessProgressLoadPolicy.currentMonday(for:sunday,calendar:calendar)
        let planWeek=FitnessPlanExperiencePolicy.week(containing:sunday,calendar:calendar)
        let components=calendar.dateComponents([.year,.month,.day,.weekday],from:monday)
        XCTAssertEqual(components.year,2026)
        XCTAssertEqual(components.month,8)
        XCTAssertEqual(components.day,3)
        XCTAssertEqual(components.weekday,2)
        XCTAssertEqual(planWeek.count,7)
        XCTAssertTrue(try XCTUnwrap(planWeek.first).isSameDay(as:monday,calendar:calendar))
    }

    func testChosenGoalSelectsAHumanTrendWithoutExposingItsMetricKey() {
        XCTAssertEqual(FitnessGoalTrendKind.resolve(metric:"activity.sessions.weekly"),.sessions)
        XCTAssertEqual(FitnessGoalTrendKind.resolve(metric:"activity.active_days.weekly"),.activeDays)
        XCTAssertEqual(FitnessGoalTrendKind.resolve(metric:"running.distance_m.weekly"),.runningDistance)
        XCTAssertEqual(FitnessGoalTrendKind.resolve(metric:"strength.sessions.weekly"),.strengthSessions)
        XCTAssertEqual(FitnessGoalTrendKind.resolve(metric:"body.weight.kg"),.weight)

        for kind in [
            FitnessGoalTrendKind.sessions,.activeDays,.runningDistance,.strengthSessions,.weight,
        ] {
            XCTAssertTrue(FitnessConsumerCopyPolicy.isConsumerFacing(kind.title),kind.title)
            XCTAssertFalse(kind.title.contains("."),"Private goal keys must never appear in chart titles")
        }
    }

    func testGoalTemplateAndWeeklyReviewDecodeHumanWireContracts() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let template=try decoder.decode(FitnessGoalTemplate.self,from:Data(#"""
        {"id":"run-weekly-distance","title":"Run further","description":"Choose a weekly distance.",
        "target_prompt":"How many kilometres?","input_kind":"kilometres_per_week",
        "unit_label":"kilometres per week","minimum_value":0.5,"maximum_value":300,
        "step":0.5,"suggested_value":15,"supports_target_date":true}
        """#.utf8))
        XCTAssertEqual(template.title,"Run further")
        XCTAssertEqual(template.inputKind,.kilometresPerWeek)

        let faster=try decoder.decode(FitnessGoalTemplate.self,from:Data(#"""
        {"id":"run-faster-5k","title":"Run a faster 5K","description":"Choose the 5K time you want to work towards.",
        "target_prompt":"What 5K time are you aiming for?","input_kind":"duration_minutes_seconds",
        "unit_label":"5K time","minimum_value":720,"maximum_value":7200,
        "step":1,"suggested_value":1500,"supports_target_date":true}
        """#.utf8))
        XCTAssertEqual(faster.inputKind,.durationMinutesSeconds)
        XCTAssertEqual(faster.suggestedValue,1_500)

        let review=try decoder.decode(FitnessWeeklyReview.self,from:Data(#"""
        {"week_start":"2026-08-03","week_end":"2026-08-09",
        "totals":{"completed_sessions":3,"active_days":3,"duration_minutes":140,"distance_km":12.5,"strength_volume_kg":2400},
        "goal":{"goal_id":"goal-1","goal_name":"Run further","progress_text":"12.5 of 15 km","progress_percent":83},
        "highlight":{"title":"Three active days","detail":"You kept moving across the week."},
        "opportunity":{"title":"One short run would complete the week","detail":"Plan it when it fits.",
        "destination":"plan","action":"plan_session","action_label":"Plan a run"}}
        """#.utf8))
        XCTAssertEqual(review.goal?.progressPercent,83)
        XCTAssertEqual(review.opportunity.action,.planSession)
    }

    func testProgressChartsDecodeComparableRunAndWorkingSetSeries() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let charts=try decoder.decode(FitnessProgressChartsDTO.self,from:Data(#"""
        {"weight":[{"measurement_id":"weight-1","measured_at_utc":"2026-08-01T07:00:00Z","weight_kg":80.6}],
        "running":[{"key":"5k","label":"5K","distance_m":5000,"points":[
        {"activity_id":"run-1","started_at_utc":"2026-08-02T08:00:00Z","duration_s":1500,"source":"best_effort"}]}],
        "strength":[{"key":"squat","label":"Squat","exercise_id":"exercise-1","exercise_name":"Back squat",
        "setup_id":"setup-1","setup_name":"Barbell","points":[{"activity_id":"strength-1",
        "performed_at_utc":"2026-08-03T18:00:00Z","load_kg":85,"repetitions":6,"working_set_count":3}]}]}
        """#.utf8))

        XCTAssertEqual(charts.weight.first?.weightKg,80.6)
        XCTAssertEqual(charts.running.first?.points.first?.source,.bestEffort)
        XCTAssertEqual(charts.strength.first?.exerciseName,"Back squat")
        XCTAssertEqual(charts.strength.first?.points.first?.workingSetCount,3)
    }

    func testMeasurementGraphExposesStableDisplayScaleAndTimeOptions() {
        XCTAssertEqual(FitnessMeasurementDisplayMode.allCases, [.trend, .raw])
        XCTAssertEqual(FitnessMeasurementDisplayMode.trend.title, "Smoothed")
        XCTAssertEqual(FitnessMeasurementDisplayMode.raw.title, "Raw")
        XCTAssertEqual(FitnessMeasurementYAxisScale.defaultScale, .fit)
        XCTAssertEqual(FitnessMeasurementYAxisScale.allCases, [.tight, .fit, .wide])
        XCTAssertEqual(
            FitnessMeasurementRange.allCases.map(\.compactTitle),
            ["7D", "30D", "90D", "1Y"]
        )
    }

    func testMeasurementVerticalScaleChangesPaddingWithoutFlatteningToZero() {
        let values = [79.0, 81.0]
        let tight = FitnessMeasurementChartDomainPolicy.domain(
            values: values, metric: .weight, scale: .tight
        )
        let fit = FitnessMeasurementChartDomainPolicy.domain(
            values: values, metric: .weight, scale: .fit
        )
        let wide = FitnessMeasurementChartDomainPolicy.domain(
            values: values, metric: .weight, scale: .wide
        )

        XCTAssertEqual(tight.lowerBound, 78.75, accuracy: 0.001)
        XCTAssertEqual(tight.upperBound, 81.25, accuracy: 0.001)
        XCTAssertEqual(fit.lowerBound, 78, accuracy: 0.001)
        XCTAssertEqual(fit.upperBound, 82, accuracy: 0.001)
        XCTAssertEqual(wide.lowerBound, 77, accuracy: 0.001)
        XCTAssertEqual(wide.upperBound, 83, accuracy: 0.001)
        XCTAssertGreaterThan(tight.lowerBound, 0)
        XCTAssertLessThan(wide.lowerBound, tight.lowerBound)
    }

    func testMeasurementRenderingBoundsChartMarksButKeepsFullHistoryAvailable() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = 2 * 3_600.0
        let points = (0..<1_228).map { index in
            let measuredAt = start.addingTimeInterval(Double(index) * interval)
            return FitnessMeasurementHistoryPointDTO(
                id: "weight-\(index)",
                measuredAtUtc: FitnessDatabase.dateString(measuredAt),
                rawValue: 80 + Double(index % 10) / 10,
                trendValue: 80 + Double(index % 20) / 20,
                sourceLabel: "Withings"
            )
        }
        let viewportStart = start.addingTimeInterval(5 * 86_400)
        let viewportEnd = viewportStart.addingTimeInterval(90 * 86_400)

        let line = FitnessMeasurementChartRenderingPolicy.linePoints(
            from: points,
            viewportStart: viewportStart,
            visibleDays: 90
        )
        let dots = FitnessMeasurementChartRenderingPolicy.pointMarks(
            from: points,
            viewportStart: viewportStart,
            visibleDays: 90
        )

        XCTAssertEqual(points.count, 1_228, "Rendering must not discard stored history")
        XCTAssertEqual(line.count, FitnessMeasurementChartRenderingPolicy.maximumLinePointCount)
        XCTAssertEqual(dots.count, FitnessMeasurementChartRenderingPolicy.maximumPointMarkCount)
        XCTAssertEqual(line.first?.id, points.first?.id)
        XCTAssertEqual(line.last?.id, points.last?.id)
        XCTAssertTrue(dots.allSatisfy {
            guard let date = $0.measuredAt else { return false }
            return date >= viewportStart && date <= viewportEnd
        })

        let nearReading = points[600].measuredAt!.addingTimeInterval(30)
        XCTAssertEqual(
            FitnessMeasurementChartRenderingPolicy.nearestPoint(in: points, to: nearReading)?.id,
            points[600].id
        )
    }

    func testMeasurementPinchZoomIsContinuousAndClampedToUsefulBounds() {
        XCTAssertEqual(
            FitnessMeasurementChartRenderingPolicy.visibleDaysAfterPinch(
                startingVisibleDays: 90,
                magnification: 2,
                maximumVisibleDays: 365
            ),
            45,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FitnessMeasurementChartRenderingPolicy.visibleDaysAfterPinch(
                startingVisibleDays: 90,
                magnification: 30,
                maximumVisibleDays: 365
            ),
            7,
            accuracy: 0.001
        )
        XCTAssertEqual(
            FitnessMeasurementChartRenderingPolicy.visibleDaysAfterPinch(
                startingVisibleDays: 90,
                magnification: 0.1,
                maximumVisibleDays: 240
            ),
            240,
            accuracy: 0.001
        )
    }

    func testMeasurementPointCachesDateAndDoesNotPersistTheCache() throws {
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedDate = originalDate.addingTimeInterval(86_400)
        var point = FitnessMeasurementHistoryPointDTO(
            id: "weight-1",
            measuredAtUtc: FitnessDatabase.dateString(originalDate),
            rawValue: 80.5,
            trendValue: 80.2,
            sourceLabel: "Withings"
        )

        XCTAssertEqual(point.measuredAt, originalDate)
        point.measuredAtUtc = FitnessDatabase.dateString(updatedDate)
        XCTAssertEqual(point.measuredAt, updatedDate)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(point)) as? [String: Any]
        )
        XCTAssertNotNil(object["measured_at_utc"])
        XCTAssertNil(object["cached_measured_at"])
    }

    func testNormalPlanAndProgressCopyRejectsTechnicalTerms() {
        for copy in [
            "This week", "Your goal", "Add a session", "Training balance",
            "Preferred source", "What changed this month?",
        ] {
            XCTAssertTrue(FitnessConsumerCopyPolicy.isConsumerFacing(copy),copy)
        }
        for copy in ["Source priority","canonical reading","unknown hardness","e1RM"] {
            XCTAssertFalse(FitnessConsumerCopyPolicy.isConsumerFacing(copy),copy)
        }
    }

    func testLegacyTopLevelAliasesMapToCanonicalDestinations() {
        XCTAssertEqual(FitnessLegacyDestination.today.resolve().destination, .overview)
        XCTAssertEqual(FitnessLegacyDestination.nutrition.resolve().destination, .log)
        XCTAssertEqual(FitnessLegacyDestination.coach.resolve().destination, .coach)

        for alias in [
            FitnessLegacyDestination.training,
            .strength,
            .runPlans,
        ] {
            XCTAssertEqual(alias.resolve().destination, .plan)
        }

        XCTAssertEqual(FitnessLegacyDestination.activities.resolve().destination, .activities)
        for alias in [
            FitnessLegacyDestination.recovery,
            .progress,
            .analysis,
            .explore,
        ] {
            XCTAssertEqual(alias.resolve().destination, .progress)
        }
    }

    func testLegacyAliasesPreserveSpecialistSurfaceAndExactTarget() {
        XCTAssertEqual(
            FitnessLegacyDestination.strength.resolve(targetId: "plan-7"),
            FitnessLegacyResolution(
                destination: .plan,
                detail: .plan(surface: .strength, targetId: "plan-7")
            )
        )
        XCTAssertEqual(
            FitnessLegacyDestination.analysis.resolve(targetId: "activity-9"),
            FitnessLegacyResolution(
                destination: .progress,
                detail: .progress(surface: .analysis, targetId: "activity-9")
            )
        )
    }

    func testExactIntentCommandsKeepTheirTarget() {
        XCTAssertEqual(
            FitnessIntentCommand.resolve(
                FitnessDeepLinkIntent(
                    destination: .plan,
                    targetId: nil,
                    actionKind: "start_strength"
                )
            ),
            .startBlankStrength
        )
        XCTAssertEqual(
            FitnessIntentCommand.resolve(
                FitnessDeepLinkIntent(
                    destination: .plan,
                    targetId: "strength-plan",
                    actionKind: "start_session"
                )
            ),
            .startPlan("strength-plan")
        )
        XCTAssertEqual(
            FitnessIntentCommand.resolve(
                FitnessDeepLinkIntent(
                    destination: .plan,
                    targetId: "move-plan",
                    actionKind: "move_session"
                )
            ),
            .editPlan("move-plan")
        )
        XCTAssertEqual(
            FitnessIntentCommand.resolve(
                FitnessDeepLinkIntent(
                    destination: .plan,
                    targetId: "active-workout",
                    actionKind: "resume_activity"
                )
            ),
            .resumeWorkout("active-workout")
        )
        XCTAssertEqual(
            FitnessIntentCommand.resolve(
                FitnessDeepLinkIntent(
                    destination: .activities,
                    targetId: "activity-detail",
                    actionKind: "open_activity"
                )
            ),
            .openActivity("activity-detail")
        )
        XCTAssertEqual(
            FitnessIntentCommand.resolve(FitnessDeepLinkIntent(
                destination: .progress,
                targetId: "old-activity-link",
                actionKind: "open_activity"
            ))?.destination,
            .activities,
            "Previously issued Progress links must migrate to the Activities destination"
        )
    }

    func testLegacyIntentIsConsumedAsCanonicalDestinationWithDetail() {
        let intent = FitnessLegacyDestination.runPlans.intent(targetId: nil)

        XCTAssertEqual(intent.destination, .plan)
        XCTAssertEqual(
            FitnessIntentCommand.resolve(intent),
            .openLegacyPlan(.runPlans, targetId: nil)
        )
    }

    @MainActor
    func testIntentCoordinatorIsIdempotentAndAllowsExplicitRetryAfterFailure() {
        let coordinator = FitnessIntentCoordinator()
        let id = UUID()
        let intent = FitnessDeepLinkIntent(
            id: id,
            destination: .plan,
            targetId: "one-plan",
            actionKind: "start_session"
        )

        XCTAssertEqual(coordinator.begin(intent), .startPlan("one-plan"))
        XCTAssertNil(coordinator.begin(intent), "An in-flight intent must not execute twice")

        coordinator.finish(id: id, succeeded: false)
        XCTAssertEqual(coordinator.begin(intent), .startPlan("one-plan"))

        coordinator.finish(id: id, succeeded: true)
        XCTAssertNil(coordinator.begin(intent), "A completed intent must remain exactly-once")
    }

    @MainActor
    func testAppStatePromotesFitnessToItsOwnTabAndCompletesOnlyMatchingIntent() {
        let appState = AppState()
        appState.applyFitnessWorkspacePreference(.init(enabled:true,pinned:true))
        appState.openFitness(
            destination: .plan,
            targetId: "first",
            actionKind: "open_session"
        )
        let firstId = try! XCTUnwrap(appState.fitnessDeepLinkIntent?.id)

        appState.openFitness(
            destination: .progress,
            targetId: "second",
            actionKind: "open_activity"
        )
        let secondId = try! XCTUnwrap(appState.fitnessDeepLinkIntent?.id)

        XCTAssertEqual(appState.selectedTab, .fitness)
        XCTAssertEqual(appState.selectedFitnessDestination, .activities)
        XCTAssertEqual(appState.fitnessDeepLinkIntent?.destination, .activities)
        XCTAssertNil(appState.familyRoute)

        appState.completeFitnessDeepLink(id: firstId)
        XCTAssertEqual(appState.fitnessDeepLinkIntent?.id, secondId)

        appState.completeFitnessDeepLink(id: secondId)
        XCTAssertNil(appState.fitnessDeepLinkIntent)
    }

    @MainActor
    func testLegacyFamilyFitnessRouteRedirectsToFitnessTab() {
        let appState = AppState()
        appState.applyFitnessWorkspacePreference(.init(enabled:true,pinned:true))

        appState.openFamily(.fitness)

        XCTAssertEqual(appState.selectedTab, .fitness)
        XCTAssertEqual(appState.selectedFitnessDestination, .progress)
        XCTAssertNil(appState.familyRoute)
        XCTAssertEqual(appState.fitnessDeepLinkIntent?.destination, .progress)
    }

    func testWorkspacePreferenceDefaultsTodayNutritionOffForOlderServers() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let preference=try decoder.decode(
            FitnessWorkspacePreference.self,
            from:Data(#"{"enabled":true,"pinned":true}"#.utf8)
        )

        XCTAssertTrue(preference.enabled)
        XCTAssertTrue(preference.pinned)
        XCTAssertFalse(preference.showNutritionToday)
    }

    @MainActor
    func testEveryCoachDestinationRoutesToItsExactModuleAndTarget() throws {
        let internalRoutes:[(
            FitnessCoachProposalDestinationKind,FitnessDeepLinkDestination
        )] = [
            (.plannedSession,.plan),(.nutritionTarget,.log),(.mealTemplate,.log),
            (.goal,.plan),(.analysisChart,.progress),(.foodLog,.log),
            (.fitnessReminder,.coach),
        ]
        for (kind,expected) in internalRoutes {
            let state=AppState()
            state.applyFitnessWorkspacePreference(.init(enabled:true,pinned:true))
            let destination=FitnessCoachProposalDestination(
                kind:kind,target:"exact-\(kind.rawValue)",label:"Open result"
            )
            XCTAssertTrue(state.openFitnessCoachDestination(destination))
            XCTAssertEqual(state.selectedTab,.fitness)
            XCTAssertEqual(state.selectedFitnessDestination,expected)
            XCTAssertEqual(state.fitnessDeepLinkIntent?.targetId,destination.target)
            XCTAssertEqual(state.fitnessDeepLinkIntent?.coachDestination,destination)
            XCTAssertEqual(
                FitnessIntentCommand.resolve(try XCTUnwrap(state.fitnessDeepLinkIntent)),
                .openCoachResult(destination)
            )
        }

        let calendar=AppState()
        XCTAssertTrue(calendar.openFitnessCoachDestination(.init(
            kind:.calendarEvent,target:"event-1",label:"Open Calendar"
        )))
        XCTAssertEqual(calendar.selectedTab,.calendar)
        XCTAssertEqual(calendar.highlightedCalendarResultId,"event-1")

        let shopping=AppState()
        XCTAssertTrue(shopping.openFitnessCoachDestination(.init(
            kind:.shopping,target:"shopping-1",label:"Open Shopping"
        )))
        XCTAssertEqual(shopping.selectedTab,.lists)
        XCTAssertEqual(shopping.listsRoute,.meals)
        XCTAssertEqual(shopping.preferredMealsSection,2)
        XCTAssertEqual(shopping.highlightedShoppingResultId,"shopping-1")

        let task=AppState()
        XCTAssertTrue(task.openFitnessCoachDestination(.init(
            kind:.task,target:"task-1",label:"Open Task"
        )))
        XCTAssertEqual(task.selectedTab,.lists)
        XCTAssertEqual(task.listsRoute,.tasks)
        XCTAssertEqual(task.highlightedTaskResultId,"task-1")
        XCTAssertEqual(task.preferredTaskShowCompleted,false)
    }

    @MainActor
    func testDisabledFitnessKeepsItsExactIntentBehindPrivateOptIn() {
        let state=AppState()
        state.selectedTab = .calendar

        state.openFitness(
            destination:.progress,targetId:"activity-1",actionKind:"open_activity"
        )

        XCTAssertEqual(state.selectedTab,.calendar)
        XCTAssertTrue(state.showingFitnessOptIn)
        XCTAssertEqual(state.fitnessDeepLinkIntent?.targetId,"activity-1")
        XCTAssertEqual(state.selectedFitnessDestination,.activities)
    }

    @MainActor
    func testUnknownCoachDestinationFailsClosedWithoutNavigationMutation() {
        let state=AppState()
        state.selectedTab = .calendar
        state.highlightedCalendarResultId="existing"
        let before=state.selectedTab

        XCTAssertFalse(state.openFitnessCoachDestination(.init(
            kind:.unknown("future"),target:"future-1",label:"Future"
        )))
        XCTAssertEqual(state.selectedTab,before)
        XCTAssertEqual(state.highlightedCalendarResultId,"existing")
        XCTAssertNil(state.fitnessDeepLinkIntent)
        XCTAssertNil(FitnessIntentCommand.resolve(.init(
            destination:.coach,targetId:"future-1",actionKind:"open_coach_result",
            coachDestination:.init(
                kind:.unknown("future"),target:"future-1",label:"Future"
            )
        )))
    }

    @MainActor
    func testCoachDraftHandoffIsExactOwnerBoundNonOverwritingAndConsumedOnce() throws {
        let state=AppState()
        let ownerA=UserProfile(
            id:"user-a",name:"A",email:"demo-person-44@example.invalid",role:"user",priority:5,
            familyId:"family-a"
        )
        let ownerB=UserProfile(
            id:"user-b",name:"B",email:"demo-person-46@example.invalid",role:"user",priority:10,
            familyId:"family-a"
        )
        state.currentUser=ownerA
        let exact="  Plan a 5K\nwithout moving Saturday  "
        let nonce=try XCTUnwrap(
            state.stageFitnessCoachDraft(exact,contextIds:["activity-1"])
        )

        XCTAssertNil(
            state.consumeFitnessCoachDraft(nonce:nonce,currentDraft:"My existing Coach draft"),
            "A non-empty Coach composer must always win"
        )
        XCTAssertEqual(state.fitnessCoachDraftText,exact)
        let handoff=try XCTUnwrap(
            state.consumeFitnessCoachHandoff(nonce:nonce,currentDraft:"   ")
        )
        XCTAssertEqual(handoff.text,exact)
        XCTAssertEqual(handoff.contextIds,["activity-1"])
        XCTAssertTrue(state.fitnessCoachContextIds.isEmpty)
        XCTAssertNil(state.consumeFitnessCoachDraft(nonce:nonce,currentDraft:""))

        state.assistantDraftText="private Bismarck draft"
        _=state.stageFitnessCoachDraft("owner A only")
        state.currentUser=ownerB
        XCTAssertNil(state.fitnessCoachDraftText)
        XCTAssertNil(state.fitnessCoachDraftNonce)
        XCTAssertNil(state.assistantDraftText)
        XCTAssertNotEqual(
            FitnessCoachWorkspacePolicy.key(for:ownerA.id),
            FitnessCoachWorkspacePolicy.key(for:ownerB.id)
        )
    }

    private func plan(
        id:String,status:String,date:Date,isCompleted:Bool=false
    ) -> FitnessPlannedSession {
        FitnessPlannedSession(
            id:id,title:id,plannedFor:date,exerciseIds:[],isCompleted:isCompleted,
            revision:1,updatedAt:date,status:status
        )
    }
}

private extension Date {
    func isSameDay(as other:Date,calendar:Calendar) -> Bool {
        calendar.isDate(self,inSameDayAs:other)
    }
}
