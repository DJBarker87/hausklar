import XCTest
import GRDB
@testable import HausKlar

final class FitnessStrengthContractTests: XCTestCase {
    private var directory: URL!
    private var database: FitnessDatabase!
    private var repository: FitnessRepository!

    override func setUpWithError() throws {
        directory=FileManager.default.temporaryDirectory
            .appendingPathComponent("FitnessStrengthTests-\(UUID().uuidString)",isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        database=FitnessDatabase()
        try database.activateForTesting(storeURL: directory.appendingPathComponent("fitness.sqlite"))
        repository=FitnessRepository(database: database,deviceId: "strength-contract-test")
    }

    override func tearDownWithError() throws {
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    func testStoppedForBodyIssueIsWireExactAndNeverHardOrE1RM() {
        let group=FitnessSetGroup(
            id: "group",sessionExerciseId: "exercise",role: .working,structure: .straight,
            isAMRAP: true,failureState: .stoppedForBodyIssue,status: .completed,
            position: 0,revision: 0,updatedAt: Date()
        )
        let component=makeComponent(reps: 5,repsLeft: nil,repsRight: nil,rir: nil,rpe: nil)
        XCTAssertEqual(group.failureState.rawValue,"stopped_for_body_issue")
        XCTAssertFalse(FitnessCalculations.isHardSet(group: group,components: [component]))
        XCTAssertNil(FitnessCalculations.eligibleEpley(group: group,components: [component]))
    }

    func testUnilateralRepetitionsDoNotBecomeScalarE1RM() {
        let group=FitnessSetGroup(
            id: "group",sessionExerciseId: "exercise",role: .working,structure: .straight,
            isAMRAP: false,failureState: .none,status: .completed,
            position: 0,revision: 0,updatedAt: Date()
        )
        let component=makeComponent(reps: nil,repsLeft: 8,repsRight: 8,rir: 1,rpe: nil)
        XCTAssertTrue(FitnessCalculations.isPerformed(component))
        XCTAssertNil(FitnessCalculations.eligibleEpley(group: group,components: [component]))
    }

    func testUnilateralSidesSumForVolumeButUseNoScalarE1RM() {
        let group=FitnessSetGroup(
            id: "group",sessionExerciseId: "exercise",role: .working,structure: .straight,
            isAMRAP: false,failureState: .none,status: .completed,
            position: 0,revision: 0,updatedAt: Date()
        )
        let component=makeComponent(reps: nil,repsLeft: 8,repsRight: 7,rir: 1,rpe: nil)
        XCTAssertEqual(FitnessCalculations.volume([component]),1_200)
        XCTAssertNil(FitnessCalculations.eligibleEpley(group: group,components: [component]))
    }

    func testPlannedReadinessAttachesToStartedSessionWithoutCreatingADuplicate() async throws {
        let exercise=try await repository.createExercise(name: "Row",category: "pull",loadMode: .total)
        let plan=try await repository.createPlannedSession(
            title: "Readiness plan",plannedFor: Date(),exerciseIds: [exercise.id]
        )
        let checkinId=try await repository.recordPlannedReadiness(planId: plan.id,value: 4)
        let plannedReadiness=try await repository.plannedReadiness(planId: plan.id)
        XCTAssertEqual(plannedReadiness,4)

        let session=try await repository.startWorkout(title: plan.title,planId: plan.id)
        XCTAssertEqual(session.readiness,4)
        let rows: [Row] = try database.read { db in
            try Row.fetchAll(
                db,sql: "SELECT id,session_id,planned_session_id FROM fitness_session_checkins WHERE planned_session_id=?",
                arguments: [plan.id]
            )
        }
        XCTAssertEqual(rows.count,1)
        let row=try XCTUnwrap(rows.first)
        let rowId: String=row["id"]
        let attachedSessionId: String=row["session_id"]
        XCTAssertEqual(rowId,checkinId)
        XCTAssertEqual(attachedSessionId,session.id)
    }

    func testStrengthMergePreviewsDecodeWireExactAffectedCounts() throws {
        let decoder=JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let exercise=try decoder.decode(
            FitnessExerciseMergePreview.self,
            from: Data(#"{"source_id":"a","target_id":"b","already_merged":false,"planned_exercises":2,"session_exercises":3,"moved_setups":1}"#.utf8)
        )
        XCTAssertEqual(exercise.plannedExercises,2)
        XCTAssertEqual(exercise.sessionExercises,3)
        XCTAssertEqual(exercise.movedSetups,1)
        let setup=try decoder.decode(
            FitnessExerciseSetupMergePreview.self,
            from: Data(#"{"source_id":"s1","target_id":"s2","already_merged":false,"planned_exercises":4,"session_exercises":5}"#.utf8)
        )
        XCTAssertEqual(setup.plannedExercises,4)
        XCTAssertEqual(setup.sessionExercises,5)
    }

    func testStartMaterialisesPlannedSetShellsWithConcreteSetup() async throws {
        let exercise=try await repository.createExercise(name: "Front squat",category: "squat",loadMode: .total)
        let plan=try await repository.createPlannedSession(
            title: "Planned strength",plannedFor: Date(),exerciseIds: [exercise.id],workingSets: 3,targetReps: 5
        )
        let session=try await repository.startWorkout(
            title: plan.title,planId: plan.id,readiness: 4,
            bodyweight: .init(kilograms: 75,source: .manual)
        )
        let workout=try await repository.workoutExercises(sessionId: session.id)
        let item=try XCTUnwrap(workout.first)
        XCTAssertFalse(item.exercise.setupId.isEmpty)
        XCTAssertFalse(item.exercise.setupName.isEmpty)
        XCTAssertEqual(item.groups.count,3)
        XCTAssertEqual(item.groups.map(\.group.status),[.planned,.planned,.planned])
        XCTAssertEqual(Set(item.groups.compactMap(\.group.plannedSetId)).count,3)
        XCTAssertEqual(session.bodyweightKgSnapshot,75)
    }

    func testMissingPlanSetupFailsWholeStartInsteadOfOmittingExercise() async throws {
        let exercise=try await repository.createExercise(name: "Press",category: "push",loadMode: .total)
        let plan=try await repository.createPlannedSession(
            title: "Broken setup plan",plannedFor: Date(),exerciseIds: [exercise.id]
        )
        try database.write { db in
            try db.execute(
                sql: "UPDATE fitness_exercise_setups SET active=0 WHERE exercise_id=?",
                arguments: [exercise.id]
            )
        }
        do {
            _=try await repository.startWorkout(title: plan.title,planId: plan.id)
            XCTFail("A planned exercise without a resolvable setup must fail visibly")
        } catch {
            let count=try database.read { db in
                try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM fitness_strength_sessions") ?? 0
            }
            XCTAssertEqual(count,0,"The session and outbox transaction must roll back")
        }
    }

    func testPerHandComponentPayloadKeepsEnteredAndNormalisedLoadsAndBodyweight() async throws {
        let exercise=try await repository.createExercise(name: "DB press",category: "push",loadMode: .each)
        let session=try await repository.startWorkout(
            title: "Dumbbells",bodyweight: .init(kilograms: 74.5,source: .manual)
        )
        let sessionExercise=try await repository.addExercise(exercise.id,to: session.id)
        _=try await repository.saveSet(
            to: sessionExercise.id,sessionId: session.id,
            draft: FitnessStrengthSetDraft(
                role: .working,structure: .straight,isAMRAP: false,groupStatus: .completed,
                componentStatus: .completed,failureState: .none,reps: 8,loadValue: 20,
                loadUnit: "kg",rir: 2,restBeforeSeconds: 90,tempoText: "3-1-X",
                notes: "Controlled",extraMetrics: ["bench_angle": .int(30)]
            )
        )
        let payload: [String: JSONValue] = try database.read { db in
            let json=try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT payload_json FROM fitness_outbox WHERE entity_type='strength_set_component' ORDER BY created_at_client DESC LIMIT 1"
            ))
            return try JSONDecoder().decode([String: JSONValue].self,from: Data(json.utf8))
        }
        XCTAssertEqual(payload["load_value"]?.doubleValue,20)
        XCTAssertEqual(payload["load_entry_mode_snapshot"]?.stringValue,"per_hand")
        XCTAssertEqual(payload["normalized_external_load_kg"]?.doubleValue,40)
        XCTAssertEqual(payload["rest_before_s"]?.intValue,90)
        XCTAssertEqual(payload["tempo_text"]?.stringValue,"3-1-X")
        XCTAssertNil(payload["bodyweight_kg_snapshot"]?.doubleValue,"Ordinary external-load work does not claim bodyweight tonnage")
    }

    func testCompletedWorkoutBatchedReadsPreserveNestedProgressSemantics() async throws {
        let exercise=try await repository.createExercise(
            name: "Back squat",category: "squat",loadMode: .total
        )
        try database.write { db in
            try db.execute(
                sql: "UPDATE fitness_exercises SET muscle_roles_json=? WHERE id=?",
                arguments: [
                    #"[{"muscle_group_key":"quadriceps","role":"primary","contribution_weight":1.0}]"#,
                    exercise.id,
                ]
            )
        }
        let session=try await repository.startWorkout(title: "Batched history")
        let sessionExercise=try await repository.addExercise(exercise.id,to: session.id)
        _=try await repository.saveSet(
            to: sessionExercise.id,sessionId: session.id,
            draft: FitnessStrengthSetDraft(
                role: .working,structure: .straight,isAMRAP: false,
                groupStatus: .completed,componentStatus: .completed,
                failureState: .none,reps: 5,loadValue: 50,loadUnit: "kg",
                rir: 1,restBeforeSeconds: 120
            )
        )

        let activeDetail=try await repository.workoutExercises(sessionId: session.id)
        XCTAssertEqual(activeDetail.first?.groups.first?.components.first?.reps,5)
        try await repository.finishWorkout(
            sessionId: session.id,rpe: 8,performance: 4,note: nil
        )

        let summaries=try await repository.strengthProgress()
        let summary=try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.sessionId,session.id)
        XCTAssertEqual(summary.workingSets,1)
        XCTAssertEqual(summary.volumeKg,250)
        let progressSeries=try await repository.strengthExerciseProgress()
        let series=try XCTUnwrap(progressSeries.first)
        XCTAssertEqual(series.identity.exerciseId,exercise.id)
        XCTAssertEqual(series.points.first?.recordReps,5)
        XCTAssertEqual(series.points.first?.volumeKg,250)
        let exposures=try await repository.muscleExposure()
        let exposure=try XCTUnwrap(exposures.first)
        XCTAssertEqual(exposure.muscleGroupKey,"quadriceps")
        XCTAssertEqual(exposure.directWorkingSets,1)
        XCTAssertEqual(exposure.directHardSets,1)
    }

    func testTimedSetCanBeEditedAndExportedAsOneWorkoutBlock() async throws {
        let exercise=try await repository.createExercise(name: "Back squat",category: "squat",loadMode: .total)
        let session=try await repository.startWorkout(title: "Lower A")
        let sessionExercise=try await repository.addExercise(exercise.id,to: session.id)
        let started=Date(timeIntervalSince1970: 1_787_220_000)
        let completed=started.addingTimeInterval(42)
        let saved=try await repository.saveSet(
            to: sessionExercise.id,sessionId: session.id,
            draft: FitnessStrengthSetDraft(
                role: .working,structure: .straight,isAMRAP: false,
                groupStatus: .completed,componentStatus: .completed,
                failureState: .none,reps: 8,loadValue: 80,loadUnit: "kg",
                durationSeconds: 42,startedAt: started,completedAt: completed
            )
        )
        XCTAssertEqual(saved.group.startedAt,started)
        XCTAssertEqual(saved.group.completedAt,completed)

        _=try await repository.updateSet(
            group: saved.group,component: try XCTUnwrap(saved.components.first),sessionId: session.id,
            draft: FitnessStrengthSetDraft(
                role: .working,structure: .straight,isAMRAP: false,
                groupStatus: .completed,componentStatus: .completed,
                failureState: .muscular,reps: 7,loadValue: 82.5,loadUnit: "kg",
                durationSeconds: 42,startedAt: started,completedAt: completed
            )
        )
        try await repository.finishWorkout(sessionId: session.id,rpe: 8,performance: 4,note: "Felt strong")
        let recentSessions=try await repository.recentCompletedStrengthSessions()
        let completedSession=try XCTUnwrap(recentSessions.first)
        let workout=try await repository.workoutExercises(sessionId: session.id)
        let component=try XCTUnwrap(workout.first?.groups.first?.components.first)
        XCTAssertEqual(component.loadValue,82.5)
        XCTAssertEqual(component.reps,7)
        XCTAssertEqual(workout.first?.groups.first?.group.failureState,.muscular)

        let export=FitnessStrengthTextExport.text(session: completedSession,exercises: workout)
        XCTAssertTrue(export.contains("Strength workout: Lower A"))
        XCTAssertTrue(export.contains("82.5 kg × 7 reps"))
        XCTAssertTrue(export.contains("Failure: Muscular"))
        XCTAssertTrue(export.contains("Set time: 0:42"))
        XCTAssertTrue(export.contains("Workout notes: Felt strong"))
    }

    func testReadinessAndBodyIssuePayloadsUseCanonicalBackendLiterals() async throws {
        let session=try await repository.startWorkout(title: "Contract",readiness: 3)
        try await repository.addLateReadiness(2,sessionId: session.id)
        _=try await repository.addBodyIssue(
            NewBodyIssue(
                issueTypeKey: "tightness",bodyLocationKey: "thigh",side: "left",
                severity: 4,timing: "during",changedSession: true,
                sessionChangeKey: "reduced_load",note: "Changed the set"
            ),sessionId: session.id
        )
        let payloads: [(String,String)] = try database.read { db in
            try Row.fetchAll(
                db,sql: "SELECT entity_type,payload_json FROM fitness_outbox WHERE entity_type IN ('session_checkin','body_issue') ORDER BY created_at_client"
            ).map { ($0["entity_type"],$0["payload_json"]) }
        }
        let checkins=try payloads.filter { $0.0 == "session_checkin" }.map {
            try JSONDecoder().decode([String: JSONValue].self,from: Data($0.1.utf8))
        }
        let retrospective=try XCTUnwrap(checkins.first {
            $0["capture_quality"]?.stringValue == "retrospective"
        })
        XCTAssertEqual(retrospective["timing"]?.stringValue,"pre")
        let issueJSON=try XCTUnwrap(payloads.last { $0.0 == "body_issue" }?.1)
        let issue=try JSONDecoder().decode([String: JSONValue].self,from: Data(issueJSON.utf8))
        XCTAssertEqual(issue["issue_type_key"]?.stringValue,"tightness")
        XCTAssertEqual(issue["timing"]?.stringValue,"during")
        XCTAssertEqual(issue["side"]?.stringValue,"left")
        XCTAssertEqual(issue["session_change_key"]?.stringValue,"reduced_load")
    }

    func testLatestCanonicalBodyweightHasNoArtificialAgeCutoff() async throws {
        let measuredAt=Date().addingTimeInterval(-30 * 86_400)
        _=try await repository.addWeight(95.7,measuredAt: measuredAt)

        let bodyweight=try await repository.latestCanonicalBodyweight()
        let latest=try XCTUnwrap(bodyweight)

        XCTAssertEqual(latest.weightKg,95.7,accuracy:0.001)
        XCTAssertEqual(latest.measuredAt.timeIntervalSince1970,measuredAt.timeIntervalSince1970,accuracy:0.001)
    }

    func testBodyLocationRegistrySelectionUsesStableKeyAndPreservesUnknownHistory() {
        XCTAssertTrue(FitnessBodyLocation.fallback.contains { $0.locationKey == "wrist_hand" })
        XCTAssertEqual(
            FitnessBodyLocation.label(for: "knee",locations: FitnessBodyLocation.fallback),"Knee"
        )
        XCTAssertEqual(
            FitnessBodyLocation.label(for: "legacy_left_patella",locations: FitnessBodyLocation.fallback),
            "Custom/legacy: legacy left patella"
        )
    }

    private func makeComponent(
        reps: Int?,repsLeft: Int?,repsRight: Int?,rir: Double?,rpe: Double?
    ) -> FitnessSetComponent {
        FitnessSetComponent(
            id: "component",groupId: "group",status: .completed,loadKg: 80,reps: reps,
            durationSeconds: nil,distanceMetres: nil,rir: rir,rpe: rpe,completedAt: Date(),
            position: 0,revision: 0,updatedAt: Date(),repsLeft: repsLeft,repsRight: repsRight,
            loadValue: 80,loadUnit: "kg",loadEntryModeSnapshot: "total_external",
            normalizedExternalLoadKg: 80
        )
    }
}
