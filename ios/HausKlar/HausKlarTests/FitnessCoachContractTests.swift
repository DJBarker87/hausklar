import XCTest
@testable import HausKlar

final class FitnessCoachContractTests: XCTestCase {
    func testCoachPreferencesUseExactOwnerPrivateWireContractAndBounds() throws {
        let preferences = FitnessCoachPreferences(
            personalityPreset: .scientificHardDriving,directness: 5,
            challengeBias: .ambitious,detailLevel: .detailed,
            customInstruction: String(repeating: "x",count: 500)
        )
        XCTAssertTrue(preferences.isValid)
        let encoder=JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let object=try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(preferences)) as? [String: Any]
        )
        XCTAssertEqual(object["personality_preset"] as? String,"scientific_hard_driving")
        XCTAssertEqual(object["directness"] as? Int,5)
        XCTAssertEqual(object["challenge_bias"] as? String,"ambitious")
        XCTAssertEqual(object["detail_level"] as? String,"detailed")
        XCTAssertEqual((object["custom_instruction"] as? String)?.count,500)

        var invalid=preferences
        invalid.directness=6
        invalid.customInstruction=String(repeating: "x",count: 501)
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(FitnessCoachPersonalityPreset.balancedSupportive.defaults.directness,3)
    }

    func testCoachStatusAdvertisesProviderModelAndTypedIntents() throws {
        let value = try decode(
            FitnessCoachStatus.self,
            """
            {"status":"available","provider":"openai","model":"gpt-test","message":null,"intents":["discussion","morning","weekly","post_workout","evening","run_plan","strength_plan"]}
            """
        )
        XCTAssertEqual(value.status,.available)
        XCTAssertEqual(value.provider,"openai")
        XCTAssertEqual(value.model,"gpt-test")
        XCTAssertEqual(value.intents,FitnessCoachIntent.allCases)
    }

    func testConfirmedProposalDecodesExactHandoffAndUndoContracts() throws {
        let decision=try decode(
            FitnessCoachProposalDecision.self,
            """
            {"status":"confirmed","message":"Saved","result_ids":["definition","version","session-123"],
             "next_destinations":[{"kind":"planned_session","target":"session-123","label":"Open tempo run"}]}
            """
        )
        XCTAssertEqual(decision.nextDestinations?.first?.kind,.plannedSession)
        XCTAssertEqual(decision.nextDestinations?.first?.target,"session-123")
        let undo=try decode(
            FitnessCoachProposalUndo.self,
            """
            {"status":"undone","message":"Removed","affected_ids":["session-123"]}
            """
        )
        XCTAssertTrue(undo.succeeded)
        XCTAssertEqual(undo.affectedIds,["session-123"])
    }

    func testAllProposalKindsDecodeAndUnknownKindDoesNotBreakTheResponse() throws {
        let values:[(String,FitnessCoachProposalKind)] = [
            ("run_workout",.runWorkout),("strength_workout",.strengthWorkout),
            ("training_week",.trainingWeek),("nutrition_change",.nutritionChange),
            ("goal_adjustment",.goalAdjustment),("calendar_change",.calendarChange),
            ("family_calendar_event",.familyCalendarEvent),
            ("planned_meal_log",.plannedMealLog),("shopping_list",.shoppingList),
            ("family_task",.familyTask),("fitness_reminder",.fitnessReminder),
            ("chart",.chart),
        ]
        XCTAssertEqual(FitnessCoachProposalKind.allCases.count,12)
        for (raw,expected) in values {
            XCTAssertEqual(try decode(FitnessCoachProposalKind.self,"\"\(raw)\""),expected)
        }

        let response=try decode(
            FitnessCoachMessageResponse.self,
            """
            {"status":"complete","answer":"I can still help.","evidence":[],
             "recommendation":null,"proposal":{"id":"future-1","kind":"future_kind",
             "payload":{},"preview":null,"validation":{"valid":true,"issues":[]},
             "warnings":[],"confirmable":true,"expires_at":"2099-01-01T00:00:00Z"}}
            """
        )
        XCTAssertEqual(response.answer,"I can still help.")
        XCTAssertEqual(response.proposal?.kind,.unknown("future_kind"))
        XCTAssertFalse(try XCTUnwrap(response.proposal).canConfirm)
    }

    func testAllDestinationKindsDecodeAndUnknownDestinationDoesNotBreakConfirmation() throws {
        let decision=try decode(
            FitnessCoachProposalDecision.self,
            """
            {"status":"confirmed","message":"Saved","result_ids":[],
             "next_destinations":[
             {"kind":"planned_session","target":"1","label":"Plan"},
             {"kind":"nutrition_target","target":"2","label":"Target"},
             {"kind":"meal_template","target":"3","label":"Meal"},
             {"kind":"goal","target":"4","label":"Goal"},
             {"kind":"analysis_chart","target":"5","label":"Chart"},
             {"kind":"calendar_event","target":"6","label":"Calendar"},
             {"kind":"food_log","target":"7","label":"Diary"},
             {"kind":"shopping","target":"8","label":"Shopping"},
             {"kind":"task","target":"9","label":"Task"},
             {"kind":"fitness_reminder","target":"10","label":"Reminder"},
             {"kind":"future_destination","target":"11","label":"Future"}]}
            """
        )
        let destinations=try XCTUnwrap(decision.nextDestinations)
        XCTAssertEqual(destinations.count,11)
        XCTAssertEqual(destinations.filter(\.kind.isKnown).count,10)
        XCTAssertEqual(destinations.last?.kind,.unknown("future_destination"))
    }

    func testLegacyNullPreviewKindsProduceSafeTypedHumanReviews() throws {
        let run:[String:JSONValue]=[
            "title":.string("Easy run"),"purpose":.string("Build consistency"),
            "scheduled_date":.string("2026-08-05"),"estimated_duration_s":.int(1_800),
            "steps":.array([.object([
                "display_name":.string("Easy running"),"duration_type":.string("time_s"),
                "duration_value":.int(1_800),"instruction_text":.string("Stay conversational"),
            ])]),
        ]
        let strength:[String:JSONValue]=[
            "title":.string("Strength"),"purpose":.string("Build capacity"),
            "scheduled_date":.string("2026-08-06"),"estimated_duration_s":.int(2_400),
            "exercises":.array([.object([
                "exercise_name":.string("Back squat"),
                "sets":.array([.object([
                    "training_role":.string("working"),"reps_min":.int(5),
                    "reps_max":.int(8),"load_min":.int(60),"load_max":.int(65),
                ])]),
            ])]),
        ]
        let week:[String:JSONValue]=[
            "name":.string("Simple week"),"purpose":.string("Keep moving"),
            "starts_on":.string("2026-08-03"),"sessions":.array([.object([
                "title":.string("Easy run"),"sport_key":.string("running"),
                "scheduled_date":.string("2026-08-05"),"estimated_duration_s":.int(1_800),
                "steps":run["steps"] ?? .array([]),
            ])]),
        ]
        let proposals:[FitnessCoachProposal] = [
            proposal(kind:.runWorkout,payload:run),
            proposal(kind:.strengthWorkout,payload:strength),
            proposal(kind:.trainingWeek,payload:week),
            proposal(kind:.nutritionChange,payload:[
                "food_or_meal":.string("Weekday breakfast"),
                "proposed_change":.string("Add a protein-rich option"),
                "expected_effect":.string("A steadier morning"),
            ]),
            proposal(kind:.goalAdjustment,payload:[
                "goal_name":.string("Weekly running"),"current_target":.string("12 km"),
                "proposed_target":.string("15 km"),"reason":.string("Recent weeks feel comfortable"),
            ]),
            proposal(kind:.calendarChange,payload:[
                "title":.string("Tempo run"),"current_scheduled_date":.string("2026-08-05"),
                "proposed_start_utc":.string("2026-08-06T17:00:00Z"),
                "reason":.string("Fits the family Calendar"),
            ]),
            proposal(kind:.chart,payload:[
                "name":.string("Running consistency"),
                "measure_key":.string("running.distance_m.weekly"),
                "dimension_key":.string("calendar.week"),
                "chart_type_key":.string("line"),"date_window_days":.int(28),
            ]),
        ]

        XCTAssertEqual(proposals.map(\.kind),[
            .runWorkout,.strengthWorkout,.trainingWeek,.nutritionChange,
            .goalAdjustment,.calendarChange,.chart,
        ])
        for value in proposals {
            XCTAssertNil(value.preview,"Legacy \(value.kind) intentionally has preview:null")
            let review=try XCTUnwrap(value.humanReview,"Missing typed review for \(value.kind)")
            XCTAssertTrue(review.isComplete)
            XCTAssertEqual(review.visibility,.privateToYou)
            XCTAssertTrue(value.canConfirm,"Legacy \(value.kind) must remain confirmable")
            XCTAssertTrue(value.canEdit)
            let rendered=review.change.joined(separator:" ")
            XCTAssertFalse(rendered.contains("goal_id"))
            XCTAssertFalse(rendered.contains("planned_session_id"))
            XCTAssertFalse(rendered.contains("measure_key"))
        }
    }

    func testNewCrossModuleKindsRequireCompleteServerPreview() {
        let kinds:[FitnessCoachProposalKind]=[
            .familyCalendarEvent,.plannedMealLog,.shoppingList,.familyTask,.fitnessReminder,
        ]
        for kind in kinds {
            let missing=proposal(kind:kind,payload:[:],preview:nil)
            XCTAssertFalse(missing.canConfirm,"\(kind) must fail closed without preview")
            XCTAssertNil(missing.humanReview)

            let valid=proposal(
                kind:kind,payload:[:],
                preview:.init(
                    change:["Save the exact change you reviewed"],
                    visibility:kind == .plannedMealLog || kind == .fitnessReminder
                        ? .privateToYou : .visibleToFamily
                )
            )
            XCTAssertTrue(valid.canConfirm,"\(kind) must accept a complete preview")
            XCTAssertEqual(valid.humanReview?.change,["Save the exact change you reviewed"])
        }
    }

    @MainActor
    func testEditSeedsOnlyTheComposerFromTheSafeHumanReview() {
        let viewModel=FitnessCoachViewModel()
        let value=proposal(
            kind:.familyTask,payload:["internal_id":.string("must-not-render")],
            preview:.init(
                change:["Add a family task to pack the swimming bag"],
                visibility:.visibleToFamily
            )
        )

        XCTAssertTrue(viewModel.seedEdit(of:value))
        XCTAssertEqual(
            viewModel.inputText,
            "Please revise this suggestion: Add a family task to pack the swimming bag."
        )
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertFalse(viewModel.inputText.contains("internal_id"))
    }

    func testPreviewContextAndReminderWireContractsDecodeExactly() throws {
        let preview=try decode(
            FitnessCoachProposalPreview.self,
            #"{"change":["Add oat milk to Shopping"],"visibility":"Visible to your family"}"#
        )
        XCTAssertEqual(preview.change,["Add oat milk to Shopping"])
        XCTAssertEqual(preview.visibility,.visibleToFamily)
        XCTAssertTrue(preview.isComplete)

        let context=try decode(
            FitnessCoachContextPreferences.self,
            #"{"family_calendar":true,"household_meals":false,"weather":true}"#
        )
        XCTAssertTrue(context.familyCalendar)
        XCTAssertFalse(context.householdMeals)
        XCTAssertTrue(context.weather)

        let reminder=try decode(
            FitnessCoachReminder.self,
            """
            {"id":"reminder-1","title":"Pack running shoes",
             "remind_at_utc":"2026-08-04T07:00:00Z","notes":"By the door",
             "planned_session_id":"session-1","status":"active"}
            """
        )
        XCTAssertEqual(reminder.title,"Pack running shoes")
        XCTAssertEqual(reminder.status,.active)
    }

    func testContextReminderAndProposalRetryServicePathsAreExact() async throws {
        let recorder=FitnessCoachRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url=try XCTUnwrap(request.url)
            let body:String
            switch (request.httpMethod,url.path) {
            case ("GET","/api/fitness/coach/context-preferences"):
                body=#"{"family_calendar":true,"household_meals":false,"weather":true}"#
            case ("PATCH","/api/fitness/coach/context-preferences"):
                body=#"{"family_calendar":false,"household_meals":true,"weather":false}"#
            case ("GET","/api/fitness/coach/reminders"):
                body=#"[{"id":"reminder-1","title":"Pack shoes","remind_at_utc":"2026-08-04T07:00:00Z","notes":null,"planned_session_id":null,"status":"active"}]"#
            case ("DELETE","/api/fitness/coach/reminders/reminder-1"):
                body=""
            case ("POST","/api/fitness/coach/proposals/proposal-1/confirm"):
                body=#"{"status":"confirmed","message":"Saved","result_ids":[],"next_destinations":[]}"#
            default:
                XCTFail("Unexpected request \(request.httpMethod ?? "nil") \(url.path)")
                body=#"{"detail":"Unexpected request"}"#
            }
            let response=HTTPURLResponse(
                url:url,statusCode:200,httpVersion:nil,
                headerFields:["Content-Type":"application/json"]
            )!
            return (response,Data(body.utf8))
        }
        let configuration=URLSessionConfiguration.ephemeral
        configuration.protocolClasses=[APIClientStubURLProtocol.self]
        let client=APIClient(
            sessionConfiguration:configuration,
            resolveClientId:{ "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL="https://coach-contract-\(UUID().uuidString).example.test/api"
        _=client.installSession(
            identity:"family-a:user-a",accessToken:"access",refreshToken:"refresh"
        )
        defer { client.clearSession() }
        let service=FitnessCoachService(apiClient:client)

        _=try await service.contextPreferences()
        let updated=try await service.updateContextPreferences(
            .init(familyCalendar:false,householdMeals:true,weather:false)
        )
        XCTAssertTrue(updated.householdMeals)
        let reminders=try await service.reminders()
        XCTAssertEqual(reminders.map(\.id),["reminder-1"])
        try await service.deleteReminder("reminder-1")
        _=try await service.decide(proposalId:"proposal-1",decision:.confirm)
        _=try await service.decide(proposalId:"proposal-1",decision:.confirm)

        let requests=recorder.requests
        XCTAssertEqual(requests.map { $0.httpMethod ?? "" },[
            "GET","PATCH","GET","DELETE","POST","POST",
        ])
        XCTAssertEqual(requests.map { $0.url?.path ?? "" },[
            "/api/fitness/coach/context-preferences",
            "/api/fitness/coach/context-preferences",
            "/api/fitness/coach/reminders",
            "/api/fitness/coach/reminders/reminder-1",
            "/api/fitness/coach/proposals/proposal-1/confirm",
            "/api/fitness/coach/proposals/proposal-1/confirm",
        ])
        let patchBody=try XCTUnwrap(requests[1].httpBody)
        let object=try XCTUnwrap(
            JSONSerialization.jsonObject(with:patchBody) as? [String:Bool]
        )
        XCTAssertEqual(object,[
            "family_calendar":false,"household_meals":true,"weather":false,
        ])
    }

    func testRunProposalRetainsCompleteStepsInstructionsCuesAndGarminLimitations() throws {
        let response = try decode(FitnessCoachMessageResponse.self,runResponseJSON)
        let proposal = try XCTUnwrap(response.proposal)
        let run = try XCTUnwrap(FitnessCoachRunProposal(payload: proposal.payload))
        XCTAssertEqual(run.title,"Progression 8K")
        XCTAssertEqual(run.estimatedDistanceM,8_000)
        XCTAssertEqual(run.flattenedSteps.rows.count,3)
        XCTAssertTrue(run.flattenedSteps.complete)
        XCTAssertEqual(run.flattenedSteps.rows[1].step.instructionText,"Hold rhythm")
        XCTAssertEqual(run.flattenedSteps.rows[1].step.mentalCueText,"Quick feet")
        XCTAssertEqual(run.cues.first?.kilometre,6)
        XCTAssertEqual(run.garminLimitations,["Spoken thought is shown as a step note."])
        XCTAssertTrue(proposal.canConfirm)
    }

    func testStrengthProposalPreservesCanonicalSetupAndLogicalSetComponents() throws {
        let proposal = try decode(FitnessCoachProposal.self,strengthProposalJSON)
        let strength = try XCTUnwrap(FitnessCoachStrengthProposal(payload: proposal.payload))
        XCTAssertEqual(strength.exercises.count,1)
        let exercise = try XCTUnwrap(strength.exercises.first)
        XCTAssertEqual(exercise.exerciseId,"exercise-1")
        XCTAssertEqual(exercise.setupId,"setup-example_school-rack")
        XCTAssertEqual(exercise.setupName,"Example School rack, 20 kg bar")
        let set = try XCTUnwrap(exercise.sets.first)
        XCTAssertEqual(set.trainingRole,"working")
        XCTAssertEqual(set.structureType,"drop")
        XCTAssertEqual(set.componentCount,2)
        XCTAssertEqual(set.components.count,2)
        XCTAssertTrue(strength.previewIsComplete)
        XCTAssertTrue(proposal.canConfirm)
    }

    func testTrainingWeekPreviewIncludesExecutableSessionsAndRejectsHiddenOverflow() throws {
        let run:[String:JSONValue]=[
            "title":.string("Easy run"),"sport_key":.string("running"),
            "scheduled_date":.string("2026-08-04"),"expected_duration_s":.int(1_800),
            "steps":.array([.object([
                "display_name":.string("Easy running"),"duration_type":.string("time_s"),
                "duration_value":.int(1_800),"instruction_text":.string("Stay conversational")
            ])]),
            "cues":.array([.object(["kilometre":.int(3),"mental_cue_text":.string("Relax shoulders")])])
        ]
        let strength:[String:JSONValue]=[
            "title":.string("Strength"),"sport_key":.string("strength"),
            "scheduled_date":.string("2026-08-06"),"expected_duration_s":.int(2_400),
            "exercises":.array([.object([
                "exercise_id":.string("squat"),"exercise_name":.string("Back squat"),
                "exercise_setup_id":.string("rack"),"setup_name":.string("Rack and 20 kg bar"),
                "sets":.array([.object([
                    "training_role":.string("working"),"reps_min":.int(5),"reps_max":.int(8),
                    "load_min":.int(60),"load_max":.int(65)
                ])])
            ])])
        ]
        let payload:[String:JSONValue]=[
            "name":.string("Simple week"),"purpose":.string("Build consistency"),
            "starts_on":.string("2026-08-03"),"sessions":.array([.object(run),.object(strength)])
        ]
        let proposal=FitnessCoachProposal(
            id:"week",kind:.trainingWeek,payload:payload,
            validation:.init(valid:true,issues:[]),warnings:[],expiresAt:"2099-01-01T00:00:00Z"
        )
        let week=try XCTUnwrap(FitnessCoachTrainingWeekProposal(payload:payload))
        XCTAssertEqual(week.sessions.count,2)
        guard case .run(let parsedRun)=week.sessions[0].workout else { return XCTFail("Expected run") }
        XCTAssertEqual(parsedRun.flattenedSteps.rows.first?.step.instructionText,"Stay conversational")
        XCTAssertEqual(parsedRun.cues.first?.thought,"Relax shoulders")
        guard case .strength(let parsedStrength)=week.sessions[1].workout else { return XCTFail("Expected strength") }
        XCTAssertEqual(parsedStrength.exercises.first?.setupName,"Rack and 20 kg bar")
        XCTAssertEqual(parsedStrength.exercises.first?.sets.first?.repsMax,8)
        XCTAssertTrue(proposal.canConfirm)

        var overflowRun=run
        overflowRun["steps"] = .array((0..<61).map {
            .object(["display_name":.string("Step \($0)"),"duration_type":.string("time_s")])
        })
        var overflowPayload=payload
        overflowPayload["sessions"] = .array([.object(overflowRun)])
        let overflow=FitnessCoachProposal(
            id:"week-overflow",kind:.trainingWeek,payload:overflowPayload,
            validation:.init(valid:true,issues:[]),warnings:[],expiresAt:"2099-01-01T00:00:00Z"
        )
        XCTAssertFalse(overflow.previewIsComplete)
        XCTAssertFalse(overflow.canConfirm)
    }

    func testInvalidOrOversizedProposalCannotBeConfirmed() throws {
        var stepValues: [JSONValue] = []
        for index in 0..<61 {
            stepValues.append(.object(["display_name": .string("Step \(index)"),"duration_type": .string("distance")]))
        }
        let oversized = FitnessCoachProposal(
            id: "proposal-large",kind: .runWorkout,payload: ["steps": .array(stepValues)],
            validation: .init(valid: true,issues: []),warnings: [],expiresAt: "2099-01-01T00:00:00Z"
        )
        XCTAssertFalse(oversized.previewIsComplete)
        XCTAssertFalse(oversized.canConfirm)

        let invalid = FitnessCoachProposal(
            id: "proposal-invalid",kind: .chart,payload: [:],
            validation: .init(
                valid: false,
                issues: [.init(code: "unknown_key",path: "measure_key",message: "Not registered")]
            ),warnings: [],expiresAt: "2099-01-01T00:00:00Z"
        )
        XCTAssertFalse(invalid.canConfirm)
    }

    @MainActor
    func testMessageRequestIsBoundedTypedHistoryWithoutProposalMutationFields() throws {
        let history = (0..<FitnessCoachViewModel.maximumInMemoryTurns).map {
            FitnessCoachHistoryTurn(role: $0.isMultiple(of: 2) ? .user : .assistant,content: "Turn \($0)")
        }
        let request = FitnessCoachMessageRequest(
            message: "Review my week",intent: .weekly,history: history,
            timezone: "Europe/Berlin",clientNow: "2026-08-02T12:00:00Z",
            contextIds: ["activity-1"]
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )
        XCTAssertEqual((object["history"] as? [[String: Any]])?.count,8)
        XCTAssertEqual(object["intent"] as? String,"weekly")
        XCTAssertEqual(object["context_ids"] as? [String],["activity-1"])
        XCTAssertNil(object["confirm"])
        XCTAssertNil(object["proposal"])
        XCTAssertNil(object["sql"])
    }

    func testActivityCoachHandoffBuildsAnEditableContextualPrompt() {
        XCTAssertEqual(
            FitnessActivityCoachHandoff.prompt(title: "  Riverside 5K "),
            "Review “Riverside 5K” in the context of the activities around it. What went well, what should I learn, and what should I do next?"
        )
    }

    func testAutomaticPreviousRunComparisonDecodesForActivityDetail() throws {
        let comparisons = try decode(
            [FitnessComparableRun].self,
            """
            [{"activity":{"id":"run-previous","title":"Riverside 10K","sport_key":"running","started_at_utc":"2026-08-13T06:00:00Z","distance_m":10020,"moving_duration_s":3200},
              "score":0.98,"reasons":["similar distance"],"is_previous_similar_distance":true,
              "automatic_comparison":{"algorithm_version":"previous-similar-distance-v1","distance_label":"10K","current_distance_m":10000,"previous_distance_m":10020,"distance_delta_m":-20,"current_duration_s":3120,"previous_duration_s":3200,"duration_delta_s":-80,"duration_improvement_s":80,"current_pace_s_per_km":312,"previous_pace_s_per_km":319.36,"pace_delta_s_per_km":-7.36,"pace_improvement_s_per_km":7.36}}]
            """
        )

        let previous = try XCTUnwrap(comparisons.first)
        XCTAssertTrue(previous.isPreviousSimilarDistance == true)
        XCTAssertEqual(previous.automaticComparison?.distanceLabel,"10K")
        XCTAssertEqual(previous.automaticComparison?.paceImprovementSPerKm,7.36)
    }

    func testCoachMemoryConversationAndCandidateWireContracts() throws {
        let preferences=try decode(
            FitnessCoachPreferences.self,
            """
            {"personality_preset":"balanced_supportive","directness":3,
             "challenge_bias":"balanced","detail_level":"standard","custom_instruction":null,
             "coach_memory_enabled":true,"coach_memory_enabled_at":"2026-08-02T12:00:00Z"}
            """
        )
        XCTAssertEqual(preferences.coachMemoryEnabled,true)
        let styleEncoder=JSONEncoder(); styleEncoder.keyEncodingStrategy = .convertToSnakeCase
        let styleUpdate=try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: styleEncoder.encode(FitnessCoachPreferencesUpdate(preferences))
            ) as? [String:Any]
        )
        XCTAssertNil(styleUpdate["coach_memory_enabled"],"Style PATCH must not toggle memory")

        let conversationID="6339b8eb-479b-4bf9-8334-2729560db95a"
        let request=FitnessCoachMessageRequest(
            message: "Review today",intent: .evening,history: [],timezone: "Europe/Berlin",
            clientNow: "2026-08-02T20:00:00Z",conversationId: conversationID
        )
        let encoder=JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let requestObject=try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String:Any]
        )
        XCTAssertEqual(requestObject["conversation_id"] as? String,conversationID)
        XCTAssertNil(requestObject["owner_name"])
        XCTAssertNil(requestObject["cycle_settings"])

        let response=try decode(
            FitnessCoachMessageResponse.self,
            """
            {"status":"complete","answer":"Keep tomorrow simple.","evidence":[],
             "recommendation":null,"proposal":null,"conversation_id":"6339b8eb-479b-4bf9-8334-2729560db95a",
             "memory_candidates":[{"category":"preference","content":"Prefers short evening reviews."}]}
            """
        )
        XCTAssertEqual(response.conversationId,conversationID)
        XCTAssertEqual(response.memoryCandidates?.first?.content,"Prefers short evening reviews.")

        let detail=try decode(
            FitnessCoachConversationDetail.self,
            """
            {"id":"6339b8eb-479b-4bf9-8334-2729560db95a","title":"Evening review","last_message_at":"2026-08-02T20:00:00Z",
             "revision":2,"created_at":"2026-08-02T19:59:00Z","updated_at":"2026-08-02T20:00:00Z",
             "messages":[{"id":"message-1","conversation_id":"6339b8eb-479b-4bf9-8334-2729560db95a","sequence":1,
             "role":"user","content":"Review today","intent":"evening","created_at":"2026-08-02T20:00:00Z"}]}
            """
        )
        XCTAssertEqual(detail.messages.first?.intent,.evening)

        let update=FitnessCoachMemoryUpdate(content: "Short evening reviews",category: nil)
        let updateObject=try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(update)) as? [String:Any]
        )
        XCTAssertEqual(updateObject["content"] as? String,"Short evening reviews")
        XCTAssertTrue(updateObject["category"] is NSNull,"A cleared category must be explicit null")
    }

    func testEphemeralAnalysisMessageEncodesWithoutConversation() throws {
        let request=FitnessCoachMessageRequest(
            message: "Interpret this chart",intent: .discussion,history: [],
            timezone: "Europe/Berlin",clientNow: "2026-08-03T12:00:00Z",
            conversationId: nil,ephemeral: true
        )
        let encoder=JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object=try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String:Any]
        )
        XCTAssertEqual(object["ephemeral"] as? Bool,true)
        XCTAssertNil(object["conversation_id"])
    }

    @MainActor
    func testTurningMemoryOffKeepsExistingItemsAvailableForOwnerMaintenance() async throws {
        APIClientStubURLProtocol.install { request in
            let path=try XCTUnwrap(request.url?.path)
            let object: Any
            if request.httpMethod == "PUT",path.hasSuffix("/fitness/coach/memory/settings") {
                object=["enabled":false,"enabled_at":"2026-08-02T12:00:00Z"]
            } else if request.httpMethod == "PATCH",path.hasSuffix("/fitness/coach/memories/memory-1") {
                object=["id":"memory-1","content":"Prefers direct concise reviews","category":"preference",
                        "confirmed_at":"2026-08-02T20:00:00Z","revision":2,
                        "created_at":"2026-08-02T20:00:00Z","updated_at":"2026-08-02T21:00:00Z"]
            } else if path.hasSuffix("/fitness/coach/memory/settings") {
                object=["enabled":true,"enabled_at":"2026-08-02T12:00:00Z"]
            } else if path.hasSuffix("/fitness/coach/conversations/conversation-1") {
                object=["id":"conversation-1","title":"Evening review",
                        "last_message_at":"2026-08-02T20:00:00Z","revision":1,
                        "created_at":"2026-08-02T20:00:00Z","updated_at":"2026-08-02T20:00:00Z",
                        "messages":[["id":"message-1","conversation_id":"conversation-1",
                                     "sequence":1,"role":"user","content":"Review today",
                                     "intent":"evening","created_at":"2026-08-02T20:00:00Z"]]]
            } else if path.hasSuffix("/fitness/coach/conversations") {
                object=[["id":"conversation-1","title":"Evening review",
                         "last_message_at":"2026-08-02T20:00:00Z","revision":1,
                         "created_at":"2026-08-02T20:00:00Z","updated_at":"2026-08-02T20:00:00Z"]]
            } else if path.hasSuffix("/fitness/coach/memories") {
                object=[["id":"memory-1","content":"Prefers concise reviews","category":"preference",
                         "confirmed_at":"2026-08-02T20:00:00Z","revision":1,
                         "created_at":"2026-08-02T20:00:00Z","updated_at":"2026-08-02T20:00:00Z"]]
            } else {
                throw URLError(.badURL)
            }
            let data=try JSONSerialization.data(withJSONObject: object)
            let response=HTTPURLResponse(
                url: try XCTUnwrap(request.url),statusCode: 200,httpVersion: nil,
                headerFields: ["Content-Type":"application/json"]
            )!
            return (response,data)
        }
        let configuration=URLSessionConfiguration.ephemeral
        configuration.protocolClasses=[APIClientStubURLProtocol.self]
        let client=APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL="https://coach-memory-\(UUID().uuidString).example.test/api"
        _=client.installSession(
            identity: "test-family:test-user",accessToken: "access",refreshToken: "refresh"
        )
        defer { client.clearSession() }
        let viewModel=FitnessCoachViewModel(service: FitnessCoachService(apiClient: client))

        await viewModel.loadMemoryState(isOnline: true)
        XCTAssertTrue(viewModel.memoryEnabled)
        XCTAssertEqual(viewModel.conversations.count,1)
        XCTAssertEqual(viewModel.memories.count,1)

        await viewModel.setMemoryEnabled(false,isOnline: true)
        XCTAssertFalse(viewModel.memoryEnabled)
        XCTAssertEqual(viewModel.conversations.map(\.id),["conversation-1"])
        XCTAssertEqual(viewModel.memories.map(\.id),["memory-1"])

        await viewModel.resumeConversation(
            try XCTUnwrap(viewModel.conversations.first),isOnline: true
        )
        XCTAssertNil(viewModel.currentConversationId)
        XCTAssertEqual(
            viewModel.memoryNotice,
            "Read-only saved copy. New replies stay temporary while Coach memory is off."
        )

        let edited = await viewModel.updateMemory(
            try XCTUnwrap(viewModel.memories.first),
            content: "Prefers direct concise reviews",category: "preference",isOnline: true
        )
        XCTAssertTrue(edited)
        XCTAssertEqual(viewModel.memories.first?.content,"Prefers direct concise reviews")
    }

    private func decode<T: Decodable>(_ type: T.Type,_ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type,from: Data(json.utf8))
    }

    private func proposal(
        kind:FitnessCoachProposalKind,payload:[String:JSONValue],
        preview:FitnessCoachProposalPreview?=nil
    ) -> FitnessCoachProposal {
        FitnessCoachProposal(
            id:"proposal-\(kind.rawValue)",kind:kind,payload:payload,preview:preview,
            validation:.init(valid:true,issues:[]),warnings:[],confirmable:true,
            expiresAt:"2099-01-01T00:00:00Z"
        )
    }

    private var runResponseJSON: String {
        """
        {"status":"complete","answer":"A controlled progression fits the record.","evidence":[{"id":"e1","kind":"run_summary","label":"Recent running","summary":"Four comparable runs","period":{"start":"2026-07-01","end":"2026-08-01"},"sample_size":4,"completeness":0.9,"source_ids":["a1"]}],"recommendation":null,"proposal":{"id":"p1","kind":"run_workout","payload":{"title":"Progression 8K","purpose":"Build controlled pace","estimated_duration_s":2700,"estimated_distance_m":8000,"expected_difficulty":"Moderate","route_assumption":"Flat loop","goal_reason":"Supports the active 10K goal","steps":[{"display_name":"Warm-up","duration_type":"distance","duration_value":1000,"instruction_text":"Start easy"},{"display_name":"Progression","duration_type":"distance","duration_value":6000,"target_type":"pace","target_low":305,"target_high":330,"target_unit":"s_per_km","instruction_text":"Hold rhythm","mental_cue_text":"Quick feet"},{"display_name":"Cool-down","duration_type":"distance","duration_value":1000,"instruction_text":"Ease down"}],"kilometre_cues":[{"kilometre":6,"instruction":"Stay controlled","cue":"Quick feet"}],"garmin_limitations":["Spoken thought is shown as a step note."]},"validation":{"valid":true,"issues":[]},"warnings":[],"expires_at":"2099-01-01T00:00:00Z"}}
        """
    }

    private var strengthProposalJSON: String {
        """
        {"id":"p2","kind":"strength_workout","payload":{"title":"Lower strength","estimated_duration_s":3600,"location":"Example School gym","exercises":[{"exercise_id":"exercise-1","exercise_name":"Back squat","setup_id":"setup-example_school-rack","setup_name":"Example School rack, 20 kg bar","sets":[{"training_role":"working","structure_type":"drop","load_min":80,"load_max":80,"load_unit":"kg_total","reps_min":5,"reps_max":6,"rir_min":2,"rir_max":3,"component_count":2,"components":[{"load_value":80,"reps":6,"rir":2},{"load_value":70,"reps":6,"rir":2}]}]}]},"validation":{"valid":true,"issues":[]},"warnings":[{"code":"issue_review","message":"Review the recorded knee observation."}],"expires_at":"2099-01-01T00:00:00Z"}
        """
    }
}

private final class FitnessCoachRequestRecorder:@unchecked Sendable {
    private let lock=NSLock()
    private var storage:[URLRequest]=[]

    func append(_ request:URLRequest) {
        var captured=request
        if captured.httpBody == nil,let stream=captured.httpBodyStream,
           let body=Self.read(stream) {
            captured.httpBody=body
        }
        lock.withLock { storage.append(captured) }
    }

    var requests:[URLRequest] { lock.withLock { storage } }

    private static func read(_ stream:InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data=Data()
        var buffer=[UInt8](repeating:0,count:1_024)
        while stream.hasBytesAvailable {
            let count=stream.read(&buffer,maxLength:buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer,count:count)
        }
        return data
    }
}
