import GRDB
import XCTest

@testable import HausKlar

/// Scale-oriented regressions for the iOS Fitness read/import paths.
///
/// The fixtures deliberately mix a 10k-row unrelated population with small,
/// reachable graphs. Before the 2026-08 quality pass these operations read the
/// complete table (and weight reranking repeatedly filtered it, O(n^2)); the
/// production queries now use indexed component frontiers/keyset pages and the
/// assertions below protect those access paths without timing-sensitive limits.
final class FitnessPerformanceTests: XCTestCase {
    private var directory: URL!
    private var database: FitnessDatabase!
    private var healthRepository: FitnessHealthRepository!
    private var repository: FitnessRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FitnessPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = FitnessDatabase()
        try database.activateForTesting(
            identity: "family-a:user-a", storeURL: directory.appendingPathComponent("fitness.sqlite")
        )
        healthRepository = FitnessHealthRepository(database: database, clientId: "performance-tests")
        repository = FitnessRepository(database: database, deviceId: "performance-tests")
    }

    override func tearDownWithError() throws {
        database.suspend()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testWeightRerankTraversesOnlyAffectedChainedComponentBesideHundredThousandRows() async throws {
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        let now = FitnessDatabase.dateString(base)
        try database.write { db in
            // One SQL bulk insert supplies a representative long-lived store
            // without making fixture construction itself timing-sensitive.
            try db.execute(
                sql: """
                    WITH digits(d) AS (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)),
                    scale(n) AS (
                      SELECT a.d*10000+b.d*1000+c.d*100+d.d*10+e.d
                      FROM digits a,digits b,digits c,digits d,digits e
                    )
                    INSERT INTO fitness_body_measurements
                    (id,measured_at,weight_kg,source,is_canonical,revision,client_updated_at,
                     origin_device_id,canonical_state,origin_provider_key,transport_key,
                     source_namespace,measurement_quality,metric_key,value_number,unit_key)
                    SELECT printf('noise-%06d',n),? ,65.0+(n%100)*0.1,'imported',1,0,?,
                           'fixture','canonical','garmin','provider_api','garmin-api',
                           'measured','body.weight_kg',65.0+(n%100)*0.1,'kg'
                    FROM scale
                    """, arguments: [now, now])
            for index in 0..<160 {
                let id = String(format: "chain-%04d", index)
                let measured = FitnessDatabase.dateString(
                    base.addingTimeInterval(Double(index + 1) * 100)
                )
                let value = 80.0 + Double(index + 1) * 0.04
                try db.execute(
                    sql: """
                        INSERT INTO fitness_body_measurements
                        (id,measured_at,weight_kg,source,is_canonical,revision,client_updated_at,
                         origin_device_id,canonical_state,origin_provider_key,transport_key,
                         source_namespace,measurement_quality,metric_key,value_number,unit_key)
                        VALUES (?,?,?,'imported',1,0,?,'fixture','canonical','withings','provider_api',
                                'withings-api','measured','body.weight_kg',?,'kg')
                        """, arguments: [id, measured, value, now, value])
            }
            // Exact external identity must bridge distant points without
            // broadening the read to every Withings/other-provider row.
            try db.execute(
                sql: "UPDATE fitness_body_measurements SET external_object_id='remote-chain' WHERE id IN ('chain-0000','chain-0159')"
            )
        }

        try await healthRepository.applyHealthKitBatch(
            kind: .bodyMass,
            samples: [
                bodySample(
                    objectId: "health-seed", externalId: "remote-chain", date: base, value: 80
                )
            ], deletions: [], archivedAnchor: Data([1])
        )

        let result = try database.read { db in
            (
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM fitness_body_measurements WHERE origin_provider_key='withings'"
                ) ?? 0,
                try String.fetchAll(
                    db,
                    sql: """
                        SELECT id FROM fitness_body_measurements
                        WHERE origin_provider_key='withings' AND is_canonical=1 ORDER BY id
                        """
                ),
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM fitness_body_measurements
                        WHERE origin_provider_key='garmin' AND is_canonical=1
                        """
                ) ?? 0
            )
        }
        XCTAssertEqual(result.0, 161)
        XCTAssertEqual(result.1, ["chain-0000"])
        XCTAssertEqual(result.2, 100_000)
        let componentPlans = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id FROM fitness_body_measurements
                    WHERE metric_key='body.weight_kg' AND origin_provider_key='withings'
                      AND deleted_at IS NULL AND measured_at BETWEEN ? AND ?
                      AND weight_kg BETWEEN 79.95 AND 80.05
                    """,
                arguments: [
                    FitnessDatabase.dateString(base.addingTimeInterval(-120)),
                    FitnessDatabase.dateString(base.addingTimeInterval(120)),
                ]
            ).map { $0["detail"] as String }.joined(separator: " ")
                + " "
                + Row.fetchAll(
                    db,
                    sql: """
                        EXPLAIN QUERY PLAN
                        SELECT id FROM fitness_body_measurements
                        WHERE metric_key='body.weight_kg' AND origin_provider_key='withings'
                          AND external_object_id='remote-chain' AND deleted_at IS NULL
                        """
                ).map { $0["detail"] as String }.joined(separator: " ")
        }
        XCTAssertTrue(componentPlans.contains("fitness_body_weight_component_idx"), componentPlans)
        XCTAssertTrue(componentPlans.contains("fitness_body_weight_external_idx"), componentPlans)
    }

    func testComparableSetsUsesSparseReachableRedirectFamilies() async throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    WITH digits(d) AS (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)),
                    scale(n) AS (
                      SELECT a.d*1000+b.d*100+c.d*10+d.d FROM digits a,digits b,digits c,digits d
                    )
                    INSERT INTO fitness_redirects(entity_type,source_id,target_id,updated_at)
                    SELECT 'exercise',printf('unrelated-%05d',n),printf('unrelated-target-%05d',n),?
                    FROM scale
                    """, arguments: [now])
            for redirect in [
                ("exercise", "exercise-old", "exercise-mid"),
                ("exercise", "exercise-mid", "exercise-current"),
                ("exercise_setup", "setup-old", "setup-current"),
            ] {
                try db.execute(
                    sql: "INSERT INTO fitness_redirects(entity_type,source_id,target_id,updated_at) VALUES (?,?,?,?)",
                    arguments: [redirect.0, redirect.1, redirect.2, now]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_sessions
                    (id,title,status,started_at,client_updated_at,origin_device_id)
                    VALUES ('past-session','Past','completed',? ,? ,'fixture')
                    """, arguments: [now, now])
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_session_exercises
                    (id,session_id,exercise_id,exercise_name,setup_id,setup_name,position,
                     client_updated_at,origin_device_id,setup_load_entry_mode_snapshot,
                     rep_count_mode_snapshot,unilateral_mode_snapshot)
                    VALUES ('past-exercise','past-session','exercise-old','Squat','setup-old','Rack',0,
                            ?,'fixture','total_external','total','bilateral')
                    """, arguments: [now])
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_set_groups
                    (id,session_exercise_id,role,structure_type,is_amrap,failure_state,status,
                     position,client_updated_at,origin_device_id)
                    VALUES ('past-group','past-exercise','working','straight',0,'none','completed',0,?,'fixture')
                    """, arguments: [now])
            try db.execute(
                sql: """
                    INSERT INTO fitness_strength_set_components
                    (id,group_id,status,load_kg,reps,position,client_updated_at,origin_device_id)
                    VALUES ('past-component','past-group','completed',100,5,0,?,'fixture')
                    """, arguments: [now])
        }
        let draft = FitnessSessionExercise(
            id: "draft", sessionId: "active", exerciseId: "exercise-current",
            exerciseName: "Squat", setupId: "setup-current", setupName: "Rack", position: 0,
            revision: 0, updatedAt: Date(), setupLoadModeSnapshot: "total_external",
            repCountModeSnapshot: "total", unilateralModeSnapshot: "bilateral"
        )

        let values = try await repository.comparableSets(for: draft, limit: 8)

        XCTAssertEqual(values.map(\.id), ["past-group"])
        XCTAssertEqual(values.first?.components.map(\.id), ["past-component"])
    }

    func testHistoryReadsAreMetricSpecificKeysetPagesAndUseReadIndexes() async throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    WITH digits(d) AS (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)),
                    scale(n) AS (
                      SELECT a.d*1000+b.d*100+c.d*10+d.d FROM digits a,digits b,digits c,digits d
                    )
                    INSERT INTO fitness_body_measurements
                    (id,measured_at,weight_kg,source,is_canonical,revision,client_updated_at,
                     origin_device_id,canonical_state,measurement_quality,metric_key,value_number,unit_key)
                    SELECT printf('body-noise-%05d',n),? ,1,'manual',1,0,?,'fixture','canonical',
                           'measured','body.unrelated',1,'unit' FROM scale;
                    """, arguments: [now, now])
            for index in 0..<510 {
                let measured = FitnessDatabase.dateString(Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
                try db.execute(
                    sql: """
                        INSERT INTO fitness_body_measurements
                        (id,measured_at,weight_kg,source,is_canonical,revision,client_updated_at,
                         origin_device_id,canonical_state,measurement_quality,metric_key,value_number,unit_key)
                        VALUES (?, ?, 80, 'manual',1,0,?,'fixture','canonical','measured',
                                'body.weight_kg',80,'kg')
                        """, arguments: ["weight-\(index)", measured, now])
            }
            for index in 0..<505 {
                let measured = FitnessDatabase.dateString(Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
                try db.execute(
                    sql: """
                        INSERT INTO fitness_recovery_observations
                        (id,metric_key,observed_at_utc,value_number,unit_key,revision,client_updated_at)
                        VALUES (?,'vitals.blood_pressure_systolic_mmhg',?,120,'mmHg',0,?)
                        """, arguments: ["bp-\(index)", measured, now])
            }
        }

        let body = try await repository.bodyMeasurementsForHistory(
            metricKeys: ["body.weight_kg"], pageSize: 128, maximumRows: 600
        )
        let recovery = try await healthRepository.recoveryObservationsForHistory(
            metricKeys: ["vitals.blood_pressure_systolic_mmhg"], pageSize: 127, maximumRows: 600
        )
        XCTAssertEqual(body.count, 510)
        XCTAssertTrue(body.allSatisfy { $0.metricKey == "body.weight_kg" })
        XCTAssertEqual(recovery.count, 505)

        let plans = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    EXPLAIN QUERY PLAN
                    SELECT id FROM fitness_body_measurements
                    WHERE metric_key='body.weight_kg' AND deleted_at IS NULL
                    ORDER BY measured_at DESC LIMIT 500
                    """
            ).map { $0["detail"] as String }.joined(separator: " ")
                + " "
                + Row.fetchAll(
                    db,
                    sql: """
                        EXPLAIN QUERY PLAN
                        SELECT id FROM fitness_recovery_observations
                        WHERE metric_key='vitals.blood_pressure_systolic_mmhg' AND deleted_at IS NULL
                        ORDER BY observed_at_utc DESC LIMIT 500
                        """
                ).map { $0["detail"] as String }.joined(separator: " ")
        }
        XCTAssertTrue(plans.contains("fitness_body_measurement_metric_time_idx"), plans)
        XCTAssertTrue(plans.contains("fitness_recovery_metric_time_idx"), plans)
    }

    func testHealthKitExactPageConcurrentObserverFailureAndReplacementTransitions() {
        XCTAssertFalse(FitnessHealthKitPagingPolicy.hasMore(sampleCount: 499, deletionCount: 0))
        XCTAssertTrue(FitnessHealthKitPagingPolicy.hasMore(sampleCount: 500, deletionCount: 0))
        XCTAssertTrue(FitnessHealthKitPagingPolicy.hasMore(sampleCount: 300, deletionCount: 200))
        XCTAssertEqual(FitnessHealthKitWorkoutOutboxPolicy.replayBatchSize, 25)
        XCTAssertEqual(FitnessHealthKitWorkoutOutboxPolicy.clampedReplayTurns(0), 1)
        XCTAssertEqual(FitnessHealthKitWorkoutOutboxPolicy.clampedReplayTurns(99), 20)
        XCTAssertEqual(FitnessHealthKitWorkoutOutboxPolicy.maximumRecords(forReplayTurns: 1), 25)
        XCTAssertEqual(FitnessHealthKitWorkoutOutboxPolicy.maximumRecords(forReplayTurns: 20), 500)

        var gate = FitnessHealthKitRunGate()
        XCTAssertTrue(gate.request(.bodyMass))
        gate.beginIteration(.bodyMass)
        XCTAssertFalse(gate.request(.bodyMass), "A concurrent observer event is coalesced")
        XCTAssertTrue(gate.shouldContinue(.bodyMass))
        gate.beginIteration(.bodyMass)
        XCTAssertFalse(gate.shouldContinue(.bodyMass), "A later-page failure leaves no false success page queued")
        gate.finish(.bodyMass)
        XCTAssertTrue(gate.running.isEmpty)

        XCTAssertTrue(gate.request(.sleepAnalysis))
        gate.requestAnotherPage(.sleepAnalysis)
        gate.reset()  // suspend/account replacement invalidates both old signals
        XCTAssertTrue(gate.running.isEmpty)
        XCTAssertTrue(gate.pending.isEmpty)
    }

    func testStreamedPhotoAdoptionValidatesJPEGAndMovesInsteadOfCopies() async throws {
        let source = directory.appendingPathComponent("source.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0xFF, 0xD9]).write(to: source)
        let adopted = try await healthRepository.adoptRepresentationFile(
            source, photoId: "photo-1", representation: "original"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: adopted.path))

        let invalid = directory.appendingPathComponent("invalid.jpg")
        try Data([0x00, 0x01, 0x02]).write(to: invalid)
        do {
            _ = try await healthRepository.adoptRepresentationFile(
                invalid, photoId: "photo-2", representation: "original"
            )
            XCTFail("A MIME label cannot make non-JPEG bytes admissible")
        } catch FitnessHealthRepositoryError.invalidPhoto {
            XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        }
    }

    private func bodySample(
        objectId: String, externalId: String?, date: Date, value: Double
    ) -> FitnessHealthKitSample {
        FitnessHealthKitSample(
            kind: .bodyMass, domainKind: .bodyMeasurement, startDate: date, endDate: date,
            value: value, unitKey: "kg", sleepStage: nil,
            provenance: FitnessHealthKitProvenance(
                sourceBundleIdentifier: "com.withings.wiscale2", sourceObjectId: objectId,
                sourceName: "Withings", productType: nil, originProviderKey: "withings",
                externalObjectId: externalId, sourceDeviceIdentifier: nil, device: [:], metadata: [:]
            )
        )
    }
}
