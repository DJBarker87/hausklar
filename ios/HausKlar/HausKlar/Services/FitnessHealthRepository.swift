import CryptoKit
import Foundation
import GRDB
import os

private let fitnessHealthRepositoryLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessHealthRepository"
)

enum FitnessHealthRepositoryError: LocalizedError {
    case invalidPhoto
    case invalidHealthKitSample
    case invalidPhotoAcknowledgement
    case missingPhoto
    case unsafePath
    case corruptPersistedRecord
    case healthKitWorkoutOutboxFull
    case corruptHealthKitWorkoutOutbox
    case invalidWorkoutAcknowledgement

    var errorDescription: String? {
        switch self {
        case .invalidPhoto: "Choose a valid image no larger than 10 MB."
        case .invalidHealthKitSample: "Health returned a sample that HausKlar could not safely store."
        case .invalidPhotoAcknowledgement: "The server did not safely acknowledge the private photo. The protected original was retained."
        case .missingPhoto: "The protected local original is no longer available."
        case .unsafePath: "HausKlar refused a private file outside this Fitness profile."
        case .corruptPersistedRecord:
            "Saved Fitness health data is damaged. Refresh from HausKlar before continuing."
        case .healthKitWorkoutOutboxFull:
            "Health workout storage is full. Connect to HausKlar and retry before importing more workouts."
        case .corruptHealthKitWorkoutOutbox:
            "A saved Health workout could not be verified, so it was not sent."
        case .invalidWorkoutAcknowledgement:
            "HausKlar did not safely acknowledge the Health workout. The saved import was retained."
        }
    }
}

enum FitnessHealthKitWorkoutOutboxPolicy {
    static let maximumRows = 10_000
    static let maximumBytes = 32 * 1_024 * 1_024
    static let maximumPayloadBytes = 32 * 1_024
    static let maximumAnchorBytes = 1 * 1_024 * 1_024
    static let replayBatchSize = 25
    static let maximumReplayTurns = 20

    static func clampedReplayTurns(_ requested: Int) -> Int {
        max(1,min(requested,maximumReplayTurns))
    }

    static func maximumRecords(forReplayTurns requested: Int) -> Int {
        replayBatchSize * clampedReplayTurns(requested)
    }
}

struct FitnessHealthKitWorkoutOutboxItem: Equatable, Sendable {
    enum Kind: String, Sendable {
        case `import`
        case resolveDelete = "resolve_delete"
    }

    let id: String
    let kind: Kind
    let workoutUuid: String
    let request: FitnessHealthKitWorkoutImport?
    let attemptCount: Int
}

struct FitnessHealthKitWorkoutOutboxStatus: Equatable, Sendable {
    let pendingCount: Int
    let permanentCount: Int
    let payloadBytes: Int
}

actor FitnessHealthRepository {
    static let shared = FitnessHealthRepository()

    private let database: FitnessDatabase
    private let fileManager: FileManager
    private let injectedClientId: String?
    private var clientId: String {
        get throws {
            if let injectedClientId { return injectedClientId }
            return try APIClient.shared.clientId
        }
    }
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        database: FitnessDatabase = .shared,fileManager: FileManager = .default,
        clientId: String? = nil
    ) {
        self.database = database
        self.fileManager = fileManager
        self.injectedClientId = clientId
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FitnessDatabase.dateString(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    // MARK: HealthKit state and atomic imports

    func healthKitImportEnabled() throws -> Bool {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM fitness_metadata WHERE key='healthkit_import_enabled'") == "1"
        }
    }

    func setHealthKitImportEnabled(_ enabled: Bool) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO fitness_metadata(key,value) VALUES ('healthkit_import_enabled',?)",
                arguments: [enabled ? "1" : "0"]
            )
        }
    }

    func anchorState(kind: FitnessHealthKitSampleKind) throws -> FitnessHealthKitAnchorState {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM fitness_healthkit_query_state WHERE sample_type=? AND predicate_version=?",
                arguments: [kind.rawValue,kind.predicateVersion]
            )
            return FitnessHealthKitAnchorState(
                sampleType: kind.rawValue,predicateVersion: kind.predicateVersion,
                anchorData: row?["anchor_data"],
                lastCompletedAt: FitnessDatabase.date(row?["last_completed_at"])
            )
        }
    }

    func latestHealthKitImport() throws -> Date? {
        try database.read { db in
            FitnessDatabase.date(try String.fetchOne(
                db,sql: "SELECT MAX(last_completed_at) FROM fitness_healthkit_query_state"
            ))
        }
    }

    func workoutSources(workoutUuid:String) throws -> [FitnessHealthKitWorkoutSource] {
        try database.read { db in
            try Row.fetchAll(
                db,sql:"SELECT * FROM fitness_healthkit_workout_sources WHERE workout_uuid=? AND state='active'",
                arguments:[workoutUuid]
            ).map { row in
                FitnessHealthKitWorkoutSource(
                    workoutUuid:row["workout_uuid"],sourceBundleIdentifier:row["source_bundle_identifier"],
                    originProviderKey:row["origin_provider_key"],externalUuid:row["external_uuid"],
                    sourceName:row["source_name"],sourceDeviceIdentifier:row["source_device_identifier"],
                    productType:row["product_type"]
                )
            }
        }
    }

    /// Commits one HealthKit workout page before any request from that page is
    /// allowed onto the network. The archived cursor and every replay record are
    /// one SQLite transaction, so a process death can produce either the old
    /// cursor or the complete new page, never an unrepeatable middle state.
    func stageWorkoutHealthKitPage(
        requests: [FitnessHealthKitWorkoutImport],
        deletedWorkoutUuids: [String],
        archivedAnchor: Data,
        completedAt: Date = Date()
    ) throws {
        guard !archivedAnchor.isEmpty,
              archivedAnchor.count <= FitnessHealthKitWorkoutOutboxPolicy.maximumAnchorBytes,
              requests.allSatisfy({ !$0.deleted && Self.validWorkoutRequest($0) }),
              deletedWorkoutUuids.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let now = FitnessDatabase.dateString(completedAt)
        try database.write { db in
            var staged: [WorkoutOutboxRecord] = []
            staged.reserveCapacity(requests.count + deletedWorkoutUuids.count)
            for request in requests {
                staged.append(try workoutOutboxRecord(request: request,now: now))
            }
            for workoutUuid in deletedWorkoutUuids {
                let sources = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM fitness_healthkit_workout_sources
                        WHERE workout_uuid=? AND state='active'
                        ORDER BY source_bundle_identifier
                        """,
                    arguments: [workoutUuid]
                )
                for source in sources {
                    let request = FitnessHealthKitWorkoutImport(
                        sourceBundleIdentifier: source["source_bundle_identifier"],
                        workoutUuid: workoutUuid,
                        originProviderKey: source["origin_provider_key"],
                        externalUuid: source["external_uuid"],sourceName: source["source_name"],
                        sourceDeviceIdentifier: source["source_device_identifier"],
                        productType: source["product_type"],sportKey: nil,subSportKey: nil,
                        title: nil,startedAtUtc: nil,endedAtUtc: nil,durationS: nil,
                        distanceM: nil,energyKcal: nil,localTimezone: nil,deleted: true
                    )
                    staged.append(try workoutOutboxRecord(request: request,now: now))
                }
                // Always reconcile against the owner-scoped server list. A
                // workout may have been imported on another device with an
                // additional bundle identity that this local database has never
                // observed; deleting only the local mappings would leave it live.
                staged.append(Self.workoutDeletionResolverRecord(workoutUuid: workoutUuid,now: now))
            }
            // If HealthKit ever reports a correction and deletion for the same
            // source in one page, the deletion record is appended last and wins.
            let unique = Dictionary(staged.map { ($0.id,$0) },uniquingKeysWith: { _,latest in latest })
            try ensureWorkoutOutboxCapacity(adding: Array(unique.values),removing: [],db: db)
            for record in unique.values.sorted(by: { $0.id < $1.id }) {
                try upsertWorkoutOutbox(record,db: db)
            }
            try db.execute(
                sql: """
                    INSERT INTO fitness_healthkit_query_state
                    (sample_type,predicate_version,anchor_data,updated_at,last_completed_at)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(sample_type,predicate_version) DO UPDATE SET
                      anchor_data=excluded.anchor_data,updated_at=excluded.updated_at,
                      last_completed_at=excluded.last_completed_at
                    """,
                arguments: [
                    FitnessHealthKitSampleKind.workout.rawValue,
                    FitnessHealthKitSampleKind.workout.predicateVersion,
                    archivedAnchor,now,now,
                ]
            )
        }
    }

    func pendingWorkoutImports(
        limit: Int = FitnessHealthKitWorkoutOutboxPolicy.replayBatchSize
    ) throws -> [FitnessHealthKitWorkoutOutboxItem] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_healthkit_workout_outbox
                    WHERE state IN ('pending','retryable')
                    ORDER BY created_at,mutation_id LIMIT ?
                    """,
                arguments: [max(1,min(limit,FitnessHealthKitWorkoutOutboxPolicy.replayBatchSize))]
            ).map { row in
                guard let kind = FitnessHealthKitWorkoutOutboxItem.Kind(
                    rawValue: row["mutation_kind"] as String
                ) else { throw FitnessHealthRepositoryError.corruptHealthKitWorkoutOutbox }
                let id: String = row["mutation_id"]
                let workoutUuid: String = row["workout_uuid"]
                let payload: String = row["payload_json"]
                let payloadBytes: Int = row["payload_byte_count"]
                guard UUID(uuidString: workoutUuid) != nil,
                      payload.utf8.count == payloadBytes,
                      payloadBytes <= FitnessHealthKitWorkoutOutboxPolicy.maximumPayloadBytes else {
                    throw FitnessHealthRepositoryError.corruptHealthKitWorkoutOutbox
                }
                let request: FitnessHealthKitWorkoutImport?
                switch kind {
                case .import:
                    request = try decode(FitnessHealthKitWorkoutImport.self,payload)
                    guard let request,
                          Self.validWorkoutRequest(request),
                          request.workoutUuid == workoutUuid,
                          id == Self.workoutMutationID(request: request) else {
                        throw FitnessHealthRepositoryError.corruptHealthKitWorkoutOutbox
                    }
                case .resolveDelete:
                    guard payload == "{}",
                          id == Self.workoutResolverMutationID(workoutUuid: workoutUuid) else {
                        throw FitnessHealthRepositoryError.corruptHealthKitWorkoutOutbox
                    }
                    request = nil
                }
                return FitnessHealthKitWorkoutOutboxItem(
                    id: id,kind: kind,workoutUuid: workoutUuid,request: request,
                    attemptCount: row["attempt_count"]
                )
            }
        }
    }

    /// Replaces one durable delete-resolution marker with the server's exact
    /// source identities. Repeating the lookup after a crash is harmless.
    func resolveWorkoutDeletion(
        itemId: String,
        workoutUuid: String,
        sources: [FitnessHealthKitWorkoutSource],
        resolvedAt: Date = Date()
    ) throws {
        guard UUID(uuidString: workoutUuid) != nil,
              itemId == Self.workoutResolverMutationID(workoutUuid: workoutUuid),
              sources.allSatisfy({
                  $0.workoutUuid == workoutUuid
                      && Self.validSourceIdentity(bundle: $0.sourceBundleIdentifier,provider: $0.originProviderKey)
              }) else { throw FitnessHealthRepositoryError.invalidHealthKitSample }
        let now = FitnessDatabase.dateString(resolvedAt)
        try database.write { db in
            guard try String.fetchOne(
                db,
                sql: """
                    SELECT mutation_kind FROM fitness_healthkit_workout_outbox
                    WHERE mutation_id=? AND workout_uuid=?
                    """,
                arguments: [itemId,workoutUuid]
            ) == FitnessHealthKitWorkoutOutboxItem.Kind.resolveDelete.rawValue else {
                return
            }
            let uniqueSources = Dictionary(
                sources.map { ($0.sourceBundleIdentifier,$0) },
                uniquingKeysWith: { _,latest in latest }
            )
            let records = try uniqueSources.values.map { source in
                try workoutOutboxRecord(
                    request: FitnessHealthKitWorkoutImport(
                        sourceBundleIdentifier: source.sourceBundleIdentifier,
                        workoutUuid: source.workoutUuid,
                        originProviderKey: source.originProviderKey,
                        externalUuid: source.externalUuid,sourceName: source.sourceName,
                        sourceDeviceIdentifier: source.sourceDeviceIdentifier,
                        productType: source.productType,sportKey: nil,subSportKey: nil,
                        title: nil,startedAtUtc: nil,endedAtUtc: nil,durationS: nil,
                        distanceM: nil,energyKcal: nil,localTimezone: nil,deleted: true
                    ),
                    now: now
                )
            }
            try ensureWorkoutOutboxCapacity(adding: records,removing: [itemId],db: db)
            for record in records.sorted(by: { $0.id < $1.id }) {
                try upsertWorkoutOutbox(record,db: db)
            }
            try db.execute(
                sql: "DELETE FROM fitness_healthkit_workout_outbox WHERE mutation_id=?",
                arguments: [itemId]
            )
        }
    }

    /// The server response and local source receipt commit with removal of the
    /// replay row. If this transaction fails after a successful request, the row
    /// deliberately survives and the exact source identity is replayed.
    func acknowledgeWorkoutImport(
        itemId: String,
        request: FitnessHealthKitWorkoutImport,
        response: FitnessHealthKitWorkoutImportResponse,
        acknowledgedAt: Date = Date()
    ) throws {
        guard itemId == Self.workoutMutationID(request: request),
              Self.validWorkoutAcknowledgement(request: request,response: response) else {
            throw FitnessHealthRepositoryError.invalidWorkoutAcknowledgement
        }
        let now = FitnessDatabase.dateString(acknowledgedAt)
        try database.write { db in
            guard try String.fetchOne(
                db,
                sql: "SELECT payload_json FROM fitness_healthkit_workout_outbox WHERE mutation_id=?",
                arguments: [itemId]
            ) == json(request) else { return }
            try db.execute(
                sql: """
                    INSERT INTO fitness_healthkit_workout_sources
                    (workout_uuid,source_bundle_identifier,origin_provider_key,external_uuid,
                     source_name,source_device_identifier,product_type,source_record_id,
                     activity_id,state,updated_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(workout_uuid,source_bundle_identifier) DO UPDATE SET
                      origin_provider_key=excluded.origin_provider_key,
                      external_uuid=excluded.external_uuid,source_name=excluded.source_name,
                      source_device_identifier=excluded.source_device_identifier,
                      product_type=excluded.product_type,source_record_id=excluded.source_record_id,
                      activity_id=excluded.activity_id,state=excluded.state,
                      updated_at=excluded.updated_at
                    """,
                arguments: [
                    request.workoutUuid,request.sourceBundleIdentifier,request.originProviderKey,
                    request.externalUuid,request.sourceName,request.sourceDeviceIdentifier,
                    request.productType,response.sourceRecordId,response.activityId,
                    request.deleted ? "deleted" : "active",now,
                ]
            )
            try db.execute(
                sql: "DELETE FROM fitness_healthkit_workout_outbox WHERE mutation_id=?",
                arguments: [itemId]
            )
        }
    }

    func recordWorkoutImportFailure(
        item: FitnessHealthKitWorkoutOutboxItem,
        message: String,
        permanent: Bool,
        attemptedAt: Date = Date()
    ) throws {
        let now = FitnessDatabase.dateString(attemptedAt)
        let expectedPayload = try item.request.map(json) ?? "{}"
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_healthkit_workout_outbox
                    SET state=?,attempt_count=attempt_count+1,last_attempt_at=?,
                        last_error=?,updated_at=?
                    WHERE mutation_id=? AND mutation_kind=? AND workout_uuid=?
                      AND payload_json=?
                    """,
                arguments: [
                    permanent ? "permanent" : "retryable",now,
                    String(message.prefix(1_000)),now,item.id,item.kind.rawValue,
                    item.workoutUuid,expectedPayload,
                ]
            )
        }
    }

    func workoutOutboxStatus() throws -> FitnessHealthKitWorkoutOutboxStatus {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                      SUM(CASE WHEN state IN ('pending','retryable') THEN 1 ELSE 0 END) AS pending_count,
                      SUM(CASE WHEN state='permanent' THEN 1 ELSE 0 END) AS permanent_count,
                      COALESCE(SUM(payload_byte_count),0) AS payload_bytes
                    FROM fitness_healthkit_workout_outbox
                    """
            )
            return FitnessHealthKitWorkoutOutboxStatus(
                pendingCount: row?["pending_count"] ?? 0,
                permanentCount: row?["permanent_count"] ?? 0,
                payloadBytes: row?["payload_bytes"] ?? 0
            )
        }
    }

    /// Samples, source mappings, tombstones, outbox rows and the archived anchor
    /// are committed by GRDB as one transaction. Any thrown row validation or
    /// SQLite error leaves the old anchor authoritative.
    func applyHealthKitBatch(
        kind: FitnessHealthKitSampleKind,
        samples: [FitnessHealthKitSample],
        deletions: [FitnessHealthKitDeletedObject],
        archivedAnchor: Data,
        completedAt: Date = Date()
    ) throws {
        guard kind != .workout else { throw FitnessHealthRepositoryError.invalidHealthKitSample }
        let now = FitnessDatabase.dateString(completedAt)
        try database.write { db in
            var affectedSleepSessions = Set<String>()
            var importedBodyMeasurementIds = Set<String>()
            var affectedWeightSeeds: [WeightSourceRow] = []
            for sample in samples {
                guard sample.kind == kind else {
                    throw FitnessHealthRepositoryError.invalidHealthKitSample
                }
                if sample.domainKind == .sleepSession {
                    try upsertHealthKitSleepSegment(
                        sample,now: now,affectedSessionIds: &affectedSleepSessions,db: db
                    )
                } else {
                    if sample.domainKind == .bodyMeasurement,
                       let prior = try weightRow(for: sample,db: db) {
                        // A HealthKit correction can move a reading out of its old
                        // duplicate component. Seed both sides of that split.
                        affectedWeightSeeds.append(prior)
                    }
                    let entityId = try upsertHealthKitSample(sample,now: now,db: db)
                    if sample.domainKind == .bodyMeasurement {
                        importedBodyMeasurementIds.insert(entityId)
                        if let current = try weightRow(id: entityId,db: db) {
                            affectedWeightSeeds.append(current)
                        }
                    }
                }
            }
            for deletion in deletions {
                guard deletion.kind == kind else {
                    throw FitnessHealthRepositoryError.invalidHealthKitSample
                }
                if deletion.kind == .bodyMass {
                    affectedWeightSeeds.append(contentsOf: try weightRows(for: deletion,db: db))
                }
                try applyHealthKitDeletion(
                    deletion,now: now,affectedSleepSessionIds: &affectedSleepSessions,db: db
                )
            }
            if kind == .bodyMass,(!samples.isEmpty || !deletions.isEmpty) {
                importedBodyMeasurementIds.formUnion(
                    try rerankWeightGroups(affectedBy: affectedWeightSeeds,now: now,db: db)
                )
                for id in importedBodyMeasurementIds.sorted() {
                    try enqueueBodyMeasurementFromRow(id: id,db: db,now: now)
                }
            }
            if kind == .sleepAnalysis {
                try rebuildSleepSessions(affectedSleepSessions,now: now,db: db)
            }
            try db.execute(
                sql: """
                    INSERT INTO fitness_healthkit_query_state
                    (sample_type,predicate_version,anchor_data,updated_at,last_completed_at)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(sample_type,predicate_version) DO UPDATE SET
                      anchor_data=excluded.anchor_data,updated_at=excluded.updated_at,
                      last_completed_at=excluded.last_completed_at
                    """,
                arguments: [kind.rawValue,kind.predicateVersion,archivedAnchor,now,now]
            )
        }
    }

    func localSleepSessions(
        startAt: Date? = nil,endAt: Date? = nil,limit: Int = 500
    ) throws -> [FitnessSleepSessionDTO] {
        try database.read { db in
            var conditions=["ss.deleted_at IS NULL"]
            var arguments:StatementArguments=[]
            if let startAt {
                conditions.append("ss.sleep_end_utc>=?")
                arguments += [FitnessDatabase.dateString(startAt)]
            }
            if let endAt {
                conditions.append("ss.sleep_start_utc<=?")
                arguments += [FitnessDatabase.dateString(endAt)]
            }
            arguments += [max(1,min(limit,2_000))]
            return try Row.fetchAll(
                db,sql: """
                    SELECT ss.id,ss.sleep_start_utc,ss.sleep_end_utc,ss.duration_s,
                           ss.awake_duration_s,ss.source_quality,ss.source_stages_json,
                           ss.source_record_id,ss.notes,ss.revision,ss.client_updated_at,
                           ss.payload_json,
                           src.transport_key AS detail_transport_key,
                           src.origin_provider_key AS detail_origin_provider_key,
                           src.source_namespace AS detail_source_namespace,
                           src.source_device_identifier AS detail_source_device_identifier,
                           src.state AS detail_source_state
                    FROM fitness_sleep_sessions ss
                    LEFT JOIN fitness_external_source_records src ON src.id=ss.source_record_id
                    WHERE \(conditions.joined(separator:" AND "))
                    ORDER BY ss.sleep_start_utc DESC,ss.id DESC LIMIT ?
                    """,arguments:arguments
            ).map { row in
                if let payload: String = row["payload_json"] {
                    var decoded = try decode(FitnessSleepSessionDTO.self,payload)
                    if decoded.source == nil { decoded.source = sourceDTO(joinedRow:row) }
                    return decoded
                }
                let stages: [FitnessSleepStageDTO] = try decodeJSON(
                    row["source_stages_json"] as String?
                ) ?? []
                return FitnessSleepSessionDTO(
                    id: row["id"],sleepStartUtc: row["sleep_start_utc"],sleepEndUtc: row["sleep_end_utc"],
                    durationS: row["duration_s"],awakeDurationS: row["awake_duration_s"],
                    sourceQuality: row["source_quality"],sourceStages: stages,
                    sourceRecordId: row["source_record_id"],
                    source: sourceDTO(joinedRow:row),notes: row["notes"],
                    revision: row["revision"],createdAt: nil,updatedAt: row["client_updated_at"],deletedAt: nil
                )
            }
        }
    }

    func localRecoveryObservations(
        metricKeys: [String]? = nil,startAt: Date? = nil,endAt: Date? = nil,
        limit: Int = 1_000
    ) throws -> [FitnessRecoveryObservationDTO] {
        try database.read { db in
            var conditions=["o.deleted_at IS NULL"]
            var arguments:StatementArguments=[]
            if let metricKeys,!metricKeys.isEmpty {
                conditions.append("o.metric_key IN (\(Array(repeating:"?",count:metricKeys.count).joined(separator:",")))")
                arguments += StatementArguments(metricKeys)
            }
            if let startAt {
                conditions.append("o.observed_at_utc>=?")
                arguments += [FitnessDatabase.dateString(startAt)]
            }
            if let endAt {
                conditions.append("o.observed_at_utc<=?")
                arguments += [FitnessDatabase.dateString(endAt)]
            }
            arguments += [max(1,min(limit,5_000))]
            return try Row.fetchAll(
                db,sql: """
                    SELECT o.id,o.metric_key,o.observed_at_utc,o.value_number,o.value_text,
                           o.unit_key,o.source_quality,o.source_record_id,o.notes,o.revision,
                           o.client_updated_at,o.payload_json,
                           src.transport_key AS detail_transport_key,
                           src.origin_provider_key AS detail_origin_provider_key,
                           src.source_namespace AS detail_source_namespace,
                           src.source_device_identifier AS detail_source_device_identifier,
                           src.state AS detail_source_state
                    FROM fitness_recovery_observations o
                    LEFT JOIN fitness_external_source_records src ON src.id=o.source_record_id
                    WHERE \(conditions.joined(separator:" AND "))
                    ORDER BY o.observed_at_utc DESC,o.id DESC LIMIT ?
                    """,arguments:arguments
            ).map { row in
                if let payload: String = row["payload_json"] {
                    var decoded = try decode(FitnessRecoveryObservationDTO.self,payload)
                    if decoded.source == nil { decoded.source = sourceDTO(joinedRow:row) }
                    return decoded
                }
                return FitnessRecoveryObservationDTO(
                    id: row["id"],metricKey: row["metric_key"],observedAtUtc: row["observed_at_utc"],
                    valueNumber: row["value_number"],valueText: row["value_text"],unitKey: row["unit_key"],
                    sourceQuality: row["source_quality"],sourceRecordId: row["source_record_id"],
                    source: sourceDTO(joinedRow:row),
                    notes: row["notes"],revision: row["revision"],createdAt: nil,
                    updatedAt: row["client_updated_at"],deletedAt: nil
                )
            }
        }
    }

    /// Keyset-paged, metric-specific chart read. Only the columns consumed by
    /// the history builder and one joined source row are materialised. The old
    /// offline path decoded every recovery payload and then filtered in Swift.
    func recoveryObservationsForHistory(
        metricKeys:[String],startAt:Date?=nil,endAt:Date?=nil,
        pageSize:Int=500,maximumRows:Int=10_000
    ) throws -> [FitnessRecoveryObservationDTO] {
        guard !metricKeys.isEmpty,maximumRows>0 else { return [] }
        return try database.read { db in
            let pageLimit=max(1,min(pageSize,1_000))
            let rowLimit=max(1,min(maximumRows,50_000))
            let placeholders=Array(repeating:"?",count:metricKeys.count).joined(separator:",")
            var result:[FitnessRecoveryObservationDTO]=[]
            var cursor:(date:String,id:String)?
            repeat {
                var conditions=[
                    "o.deleted_at IS NULL","o.metric_key IN (\(placeholders))",
                    "o.value_number IS NOT NULL",
                ]
                var arguments=StatementArguments(metricKeys)
                if let startAt {
                    conditions.append("o.observed_at_utc>=?")
                    arguments += [FitnessDatabase.dateString(startAt)]
                }
                if let endAt {
                    conditions.append("o.observed_at_utc<=?")
                    arguments += [FitnessDatabase.dateString(endAt)]
                }
                if let cursor {
                    conditions.append("(o.observed_at_utc<? OR (o.observed_at_utc=? AND o.id<?))")
                    arguments += [cursor.date,cursor.date,cursor.id]
                }
                let requested=min(pageLimit,rowLimit-result.count)
                arguments += [requested]
                let rows=try Row.fetchAll(
                    db,sql:"""
                        SELECT o.id,o.metric_key,o.observed_at_utc,o.value_number,o.value_text,
                               o.unit_key,o.source_quality,o.source_record_id,o.notes,o.revision,
                               o.client_updated_at,
                               src.transport_key AS detail_transport_key,
                               src.origin_provider_key AS detail_origin_provider_key,
                               src.source_namespace AS detail_source_namespace,
                               src.source_device_identifier AS detail_source_device_identifier,
                               src.state AS detail_source_state
                        FROM fitness_recovery_observations o
                        LEFT JOIN fitness_external_source_records src ON src.id=o.source_record_id
                        WHERE \(conditions.joined(separator:" AND "))
                        ORDER BY o.observed_at_utc DESC,o.id DESC LIMIT ?
                        """,arguments:arguments
                )
                result.append(contentsOf:rows.map { row in
                    FitnessRecoveryObservationDTO(
                        id:row["id"],metricKey:row["metric_key"],observedAtUtc:row["observed_at_utc"],
                        valueNumber:row["value_number"],valueText:row["value_text"],unitKey:row["unit_key"],
                        sourceQuality:row["source_quality"],sourceRecordId:row["source_record_id"],
                        source:sourceDTO(joinedRow:row),notes:row["notes"],revision:row["revision"],
                        createdAt:nil,updatedAt:row["client_updated_at"],deletedAt:nil
                    )
                })
                guard rows.count==requested,let last=rows.last else { break }
                cursor=(last["observed_at_utc"],last["id"])
            } while result.count<rowLimit
            return result
        }
    }

    func cacheSleepSessions(_ values: [FitnessSleepSessionDTO]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            for value in values {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_sleep_sessions
                        (id,sleep_start_utc,sleep_end_utc,duration_s,awake_duration_s,source_quality,
                         source_stages_json,source_record_id,notes,revision,client_updated_at,deleted_at,payload_json)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET
                          sleep_start_utc=excluded.sleep_start_utc,sleep_end_utc=excluded.sleep_end_utc,
                          duration_s=excluded.duration_s,awake_duration_s=excluded.awake_duration_s,
                          source_quality=excluded.source_quality,source_stages_json=excluded.source_stages_json,
                          source_record_id=excluded.source_record_id,notes=excluded.notes,
                          revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                          deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                        """,
                    arguments: [
                        value.id,value.sleepStartUtc,value.sleepEndUtc,value.durationS,value.awakeDurationS,
                        value.sourceQuality,try json(value.sourceStages ?? []),value.sourceRecordId,
                        value.notes,value.revision ?? 0,
                        value.updatedAt ?? now,value.deletedAt,try json(value),
                    ]
                )
            }
        }
    }

    func cacheRecoveryObservations(_ values: [FitnessRecoveryObservationDTO]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            for value in values {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_recovery_observations
                        (id,metric_key,observed_at_utc,value_number,value_text,unit_key,source_quality,
                         source_record_id,notes,revision,client_updated_at,deleted_at,payload_json)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET
                          metric_key=excluded.metric_key,observed_at_utc=excluded.observed_at_utc,
                          value_number=excluded.value_number,value_text=excluded.value_text,
                          unit_key=excluded.unit_key,source_quality=excluded.source_quality,
                          source_record_id=excluded.source_record_id,notes=excluded.notes,
                          revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                          deleted_at=excluded.deleted_at,payload_json=excluded.payload_json
                        """,
                    arguments: [
                        value.id,value.metricKey,value.observedAtUtc,value.valueNumber,value.valueText,
                        value.unitKey,value.sourceQuality,value.sourceRecordId,value.notes,value.revision ?? 0,
                        value.updatedAt ?? now,value.deletedAt,try json(value),
                    ]
                )
            }
        }
    }

    // MARK: Progress photos

    func createProgressPhoto(
        jpegFileURL: URL,
        capturedAt: Date,
        pose: FitnessProgressPhotoPose,
        bodyWeightKg: Double?,
        phaseId: String?,
        notes: String?,
        clientId: String,
        copyChunkSize: Int = 1_024 * 1_024,
        onChunkCopied: (@Sendable (Int) -> Void)? = nil
    ) throws -> FitnessPendingProgressPhoto {
        guard let ownerIdentity = database.activeIdentity,
              let profileRoot = database.activeStoreURL?
                .deletingLastPathComponent().standardizedFileURL,
              database.activeIdentity == ownerIdentity else {
            throw FitnessDatabaseError.notActive
        }
        let expectedByteCount = try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(
            at: jpegFileURL
        )
        guard database.activeIdentity == ownerIdentity,
              database.activeStoreURL?.deletingLastPathComponent().standardizedFileURL
                == profileRoot else {
            throw FitnessDatabaseError.staleLease
        }
        let photoId = UUID().uuidString
        let assetId = UUID().uuidString
        let directory = profileRoot.appendingPathComponent(
            "PrivateRequired/ProgressPhotos",isDirectory: true
        ).standardizedFileURL
        try LocalFileProtection.prepareDirectory(directory,fileManager: fileManager)
        let filename = "\(assetId.lowercased()).jpg"
        let destination = directory.appendingPathComponent(filename)
        let staging = directory.appendingPathComponent(".\(assetId.lowercased()).staging")
        let boundedChunkSize = min(max(1,copyChunkSize),1_024 * 1_024)
        let byteCount: Int
        do {
            guard !fileManager.fileExists(atPath: destination.path),
                  !fileManager.fileExists(atPath: staging.path) else {
                throw FitnessHealthRepositoryError.invalidPhoto
            }
            guard fileManager.createFile(
                atPath: staging.path,
                contents: nil,
                attributes: [.protectionKey: LocalFileProtection.sensitive]
            ) else {
                throw FitnessHealthRepositoryError.invalidPhoto
            }
            let input = try FileHandle(forReadingFrom: jpegFileURL)
            let output = try FileHandle(forWritingTo: staging)
            var inputIsOpen = true
            var outputIsOpen = true
            defer {
                if inputIsOpen {
                    Self.closeFileHandleAfterFallback(
                        input,context:"progress-photo source copy"
                    )
                }
                if outputIsOpen {
                    Self.closeFileHandleAfterFallback(
                        output,context:"progress-photo staging copy"
                    )
                }
            }
            var copiedByteCount = 0
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: boundedChunkSize) ?? Data()
                if chunk.isEmpty { break }
                let (nextByteCount, overflow) = copiedByteCount.addingReportingOverflow(
                    chunk.count
                )
                guard !overflow,
                      nextByteCount <= FitnessProgressPhotoPreparation.maximumJPEGBytes else {
                    throw FitnessHealthRepositoryError.invalidPhoto
                }
                try output.write(contentsOf: chunk)
                copiedByteCount = nextByteCount
                onChunkCopied?(copiedByteCount)
            }
            try Task.checkCancellation()
            try output.synchronize()
            try input.close()
            inputIsOpen = false
            try output.close()
            outputIsOpen = false
            guard copiedByteCount == expectedByteCount else {
                throw FitnessHealthRepositoryError.invalidPhoto
            }
            try LocalFileProtection.protectItem(at: staging,fileManager: fileManager)
            guard try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(at: staging)
                == expectedByteCount else {
                throw FitnessHealthRepositoryError.invalidPhoto
            }
            try Task.checkCancellation()
            try fileManager.moveItem(at: staging,to: destination)
            try LocalFileProtection.protectItem(at: destination,fileManager: fileManager)
            byteCount = try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(at: destination)
        } catch {
            removeProgressPhotoArtifactIfPresent(
                staging,context:"failed progress-photo staging"
            )
            removeProgressPhotoArtifactIfPresent(
                destination,context:"failed progress-photo publication"
            )
            throw error
        }
        if Task.isCancelled {
            removeProgressPhotoArtifactIfPresent(
                destination,context:"cancelled progress-photo publication"
            )
            throw CancellationError()
        }
        let nowDate = Date()
        let now = FitnessDatabase.dateString(nowDate)
        let captured = FitnessDatabase.dateString(capturedAt)
        let relative = "PrivateRequired/ProgressPhotos/\(filename)"
        let photo = FitnessProgressPhotoDTO(
            id: photoId,capturedAt: captured,pose: pose,bodyWeightKg: bodyWeightKg,
            measurementSnapshotJson: nil,phaseId: phaseId,phaseName: nil,
            originalAssetId: assetId,thumbnailAssetId: nil,originalState: "pending",
            thumbnailState: nil,notes: trimmed(notes),metadataAcknowledged: false,
            revision: 0,createdAt: now,updatedAt: now,deletedAt: nil
        )
        let request = FitnessProgressPhotoCreateRequest(
            id: photoId,clientId: clientId,clientTimestamp: now,capturedAt: captured,
            pose: pose,bodyWeightKg: bodyWeightKg,measurementSnapshotJson: nil,
            phaseId: phaseId,originalAssetId: assetId,notes: trimmed(notes)
        )
        do {
            try database.writeCurrent(identity: ownerIdentity) { db in
                try db.execute(
                    sql: """
                        INSERT INTO fitness_progress_photos
                        (id,captured_at,pose,body_weight_kg,phase_id,original_asset_id,original_state,
                         notes,metadata_acknowledged,revision,client_updated_at,payload_json)
                        VALUES (?,?,?,?,?,?, 'pending',?,0,0,?,?)
                        """,
                    arguments: [photoId,captured,pose.rawValue,bodyWeightKg,phaseId,assetId,trimmed(notes),now,try json(photo)]
                )
                try db.execute(
                    sql: """
                        INSERT INTO fitness_private_file_uploads
                        (asset_id,domain_entity_id,asset_kind,storage_class,relative_path,
                        original_filename,media_type,byte_count,state,created_at)
                        VALUES (?,?,'progress_photo','private_required',?,?,'image/jpeg',?,'pending_upload',?)
                        """,
                    arguments: [assetId,photoId,relative,"progress-\(pose.rawValue).jpg",byteCount,now]
                )
                try enqueue(db,type: .progressPhoto,id: photoId,operation: .upsert,payload: request,now: nowDate)
            }
        } catch {
            // Deliberately retain this durable orphan for launch reconciliation.
            throw error
        }
        return FitnessPendingProgressPhoto(
            id: assetId,photo: photo,originalFilename: "progress-\(pose.rawValue).jpg",
            mediaType: "image/jpeg",byteCount: byteCount,state: "pending_upload",
            uploadAcknowledged: false,metadataAcknowledged: false,attempts: 0,
            lastError: nil,hasLocalOriginal: true
        )
    }

    func pendingProgressPhotos() throws -> [FitnessPendingProgressPhoto] {
        try database.read { db in
            try Row.fetchAll(
                db,sql: """
                    SELECT u.*,p.payload_json AS photo_payload FROM fitness_private_file_uploads u
                    JOIN fitness_progress_photos p ON p.id=u.domain_entity_id
                    ORDER BY u.created_at
                    """
            ).map { row in
                guard let payload: String = row["photo_payload"] else {
                    throw FitnessHealthRepositoryError.corruptPersistedRecord
                }
                let photo = try decode(FitnessProgressPhotoDTO.self,payload)
                let path: String = row["relative_path"]
                let expectedByteCount: Int = row["byte_count"]
                let url = try absoluteURL(relativePath: path)
                let hasLocalOriginal: Bool
                if fileManager.fileExists(atPath:url.path) {
                    hasLocalOriginal = try FitnessProgressPhotoPreparation
                        .verifiedJPEGByteCount(at:url) == expectedByteCount
                } else {
                    hasLocalOriginal = false
                }
                return FitnessPendingProgressPhoto(
                    id: row["asset_id"],photo: photo,originalFilename: row["original_filename"],
                    mediaType: row["media_type"],byteCount: row["byte_count"],state: row["state"],
                    uploadAcknowledged: (row["upload_acknowledged"] as Int) != 0,
                    metadataAcknowledged: (row["metadata_acknowledged"] as Int) != 0,
                    attempts: row["attempt_count"],lastError: row["last_error"],
                    hasLocalOriginal: hasLocalOriginal
                )
            }
        }
    }

    func pendingProgressPhoto(photoId: String) throws -> FitnessPendingProgressPhoto? {
        try pendingProgressPhotos().first { $0.photo.id == photoId }
    }

    func localOriginalURL(assetId: String) throws -> URL {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT relative_path,byte_count FROM fitness_private_file_uploads WHERE asset_id=?",
                arguments: [assetId]
            ) else { throw FitnessHealthRepositoryError.missingPhoto }
            let path: String = row["relative_path"]
            let expectedByteCount: Int = row["byte_count"]
            let url = try absoluteURL(relativePath: path)
            guard try FitnessProgressPhotoPreparation.verifiedJPEGByteCount(at: url)
                == expectedByteCount else {
                throw FitnessHealthRepositoryError.missingPhoto
            }
            return url
        }
    }

    func markPhotoUploadAcknowledged(assetId: String,result: FitnessPrivateAssetUploadResult) throws {
        guard result.assetId == assetId,result.uploadAcknowledged,result.state == "staged",
              result.storageClass == "private_required" else {
            throw FitnessHealthRepositoryError.invalidPhotoAcknowledgement
        }
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads SET upload_acknowledged=1,
                      state='uploaded_waiting_metadata',attempt_count=attempt_count+1,
                      last_attempt_at=?,last_error=NULL WHERE asset_id=?
                    """,
                arguments: [FitnessDatabase.dateString(Date()),assetId]
            )
            try db.execute(
                sql: "UPDATE fitness_progress_photos SET original_state='staged' WHERE original_asset_id=?",
                arguments: [assetId]
            )
        }
        try cleanupAcknowledgedOriginal(assetId: assetId)
    }

    func markPhotoFailure(assetId: String,message: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads SET state='error',
                      attempt_count=attempt_count+1,last_attempt_at=?,last_error=? WHERE asset_id=?
                    """,
                arguments: [FitnessDatabase.dateString(Date()),String(message.prefix(1_000)),assetId]
            )
        }
    }

    func acknowledgePhotoMetadata(assetId: String,photo: FitnessProgressPhotoDTO) throws {
        guard photo.originalAssetId == assetId,photo.metadataAcknowledged == true else {
            throw FitnessHealthRepositoryError.invalidPhotoAcknowledgement
        }
        try database.write { db in
            try upsertProgressPhoto(photo,db: db)
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads SET metadata_acknowledged=1,
                      state=CASE WHEN upload_acknowledged=1 THEN 'acknowledged' ELSE state END,
                      last_error=NULL WHERE asset_id=?
                    """,arguments: [assetId]
            )
            try db.execute(
                sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                arguments: [FitnessEntityType.progressPhoto.rawValue,photo.id]
            )
        }
        try cleanupAcknowledgedOriginal(assetId: assetId)
    }

    func progressPhotos() throws -> [FitnessProgressPhotoDTO] {
        try database.read { db in
            try Row.fetchAll(
                db,sql: "SELECT payload_json FROM fitness_progress_photos WHERE deleted_at IS NULL ORDER BY captured_at DESC"
            ).map { row in
                guard let payload: String = row["payload_json"] else {
                    throw FitnessHealthRepositoryError.corruptPersistedRecord
                }
                return try decode(FitnessProgressPhotoDTO.self,payload)
            }
        }
    }

    func cacheProgressPhotos(_ values: [FitnessProgressPhotoDTO]) throws {
        try database.write { db in
            for value in values {
                try upsertProgressPhoto(value,db: db)
                if value.metadataAcknowledged == true {
                    try db.execute(
                        sql: """
                            UPDATE fitness_private_file_uploads SET metadata_acknowledged=1,
                              state=CASE WHEN upload_acknowledged=1 THEN 'acknowledged' ELSE state END,
                              last_error=NULL WHERE asset_id=?
                            """,arguments: [value.originalAssetId]
                    )
                    try db.execute(
                        sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                        arguments: [FitnessEntityType.progressPhoto.rawValue,value.id]
                    )
                }
            }
        }
        try cleanupAcknowledgedProgressPhotoOriginals()
    }

    func removeLocalProgressPhoto(_ photo: FitnessProgressPhotoDTO) throws {
        var localURL: URL?
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            if let path = try String.fetchOne(
                db,sql: "SELECT relative_path FROM fitness_private_file_uploads WHERE domain_entity_id=?",arguments: [photo.id]
            ) { localURL = try absoluteURL(relativePath: path) }
            try db.execute(sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",arguments: [FitnessEntityType.progressPhoto.rawValue,photo.id])
            try db.execute(sql: "DELETE FROM fitness_private_file_uploads WHERE domain_entity_id=?",arguments: [photo.id])
            try db.execute(
                sql: "UPDATE fitness_progress_photos SET deleted_at=?,client_updated_at=? WHERE id=?",
                arguments: [now,now,photo.id]
            )
        }
        if let localURL,fileManager.fileExists(atPath: localURL.path) { try fileManager.removeItem(at: localURL) }
        try removeCachedRepresentations(photoId: photo.id)
    }

    func storeRepresentation(_ data: Data,photoId: String,representation: String) throws -> URL {
        let safe = representation == "original" ? "original" : "thumbnail"
        let maximumBytes = safe == "original" ? 25 * 1_024 * 1_024 : 5 * 1_024 * 1_024
        guard !data.isEmpty,data.count<=maximumBytes,Self.isJPEG(data) else {
            throw FitnessHealthRepositoryError.invalidPhoto
        }
        let directory = try photoCacheDirectory()
        let destination = directory.appendingPathComponent("\(photoId.lowercased())-\(safe).jpg")
        try data.write(to: destination,options: [.atomic,.completeFileProtection])
        try LocalFileProtection.protectItem(at: destination,fileManager: fileManager)
        let relative = "PrivateCache/ProgressPhotos/\(destination.lastPathComponent)"
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_progress_photo_cache(photo_id,representation,relative_path,cached_at)
                    VALUES (?,?,?,?) ON CONFLICT(photo_id,representation) DO UPDATE SET
                      relative_path=excluded.relative_path,cached_at=excluded.cached_at
                    """,
                arguments: [photoId,safe,relative,FitnessDatabase.dateString(Date())]
            )
        }
        return destination
    }

    /// Adopts an authenticated streamed download without ever materialising the
    /// original image as another `Data` buffer. The file is validated before it
    /// enters the owner-scoped cache and the metadata row is written only after
    /// the protected atomic move succeeds.
    func adoptRepresentationFile(
        _ sourceURL:URL,photoId:String,representation:String
    ) throws -> URL {
        let safe=representation == "original" ? "original" : "thumbnail"
        let maximumBytes=safe == "original" ? 25 * 1_024 * 1_024 : 5 * 1_024 * 1_024
        let values=try sourceURL.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true,let byteCount=values.fileSize,
              byteCount>0,byteCount<=maximumBytes,try Self.isJPEGFile(sourceURL) else {
            throw FitnessHealthRepositoryError.invalidPhoto
        }
        let directory=try photoCacheDirectory()
        let destination=directory.appendingPathComponent("\(photoId.lowercased())-\(safe).jpg")
        let staged=directory.appendingPathComponent(".incoming-\(UUID().uuidString).jpg")
        do {
            try fileManager.moveItem(at:sourceURL,to:staged)
            try LocalFileProtection.protectItem(at:staged,fileManager:fileManager)
            if fileManager.fileExists(atPath:destination.path) {
                _=try fileManager.replaceItemAt(destination,withItemAt:staged)
            } else {
                try fileManager.moveItem(at:staged,to:destination)
            }
            try LocalFileProtection.protectItem(at:destination,fileManager:fileManager)
            let relative="PrivateCache/ProgressPhotos/\(destination.lastPathComponent)"
            try database.write { db in
                try db.execute(
                    sql:"""
                        INSERT INTO fitness_progress_photo_cache(photo_id,representation,relative_path,cached_at)
                        VALUES (?,?,?,?) ON CONFLICT(photo_id,representation) DO UPDATE SET
                          relative_path=excluded.relative_path,cached_at=excluded.cached_at
                        """,arguments:[photoId,safe,relative,FitnessDatabase.dateString(Date())]
                )
            }
            return destination
        } catch {
            removeProgressPhotoArtifactIfPresent(
                staged,context:"failed downloaded progress-photo adoption"
            )
            throw error
        }
    }

    func cachedRepresentation(photoId: String,representation: String) throws -> URL? {
        try database.read { db in
            guard let path = try String.fetchOne(
                db,sql: "SELECT relative_path FROM fitness_progress_photo_cache WHERE photo_id=? AND representation=?",
                arguments: [photoId,representation]
            ) else { return nil }
            let url = try absoluteURL(relativePath: path)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Reclaims stale files left after a crash between protected-file
    /// publication and the owner-bound SQLite commit. Enumeration is streamed,
    /// and only the exact UUID-owned final/staging shapes consume either bound.
    @discardableResult
    func reconcileProgressPhotoFiles(
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        maximumCandidates: Int = 128,
        maximumRemovals: Int = 32
    ) throws -> Int {
        guard maximumCandidates > 0, maximumRemovals > 0 else { return 0 }
        guard let ownerIdentity = database.activeIdentity,
              let profileRoot = database.activeStoreURL?
                .deletingLastPathComponent().standardizedFileURL,
              database.activeIdentity == ownerIdentity else {
            throw FitnessDatabaseError.notActive
        }
        let directory = profileRoot.appendingPathComponent(
            "PrivateRequired/ProgressPhotos",isDirectory: true
        ).standardizedFileURL
        try LocalFileProtection.prepareDirectory(directory,fileManager: fileManager)
        let directoryValues = try directory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw FitnessHealthRepositoryError.unsafePath
        }

        let relativePaths = try database.readCurrent(identity: ownerIdentity) { db in
            try String.fetchAll(
                db,
                sql: "SELECT relative_path FROM fitness_private_file_uploads"
            )
        }
        var referenced = Set<String>()
        for relativePath in relativePaths {
            let url = profileRoot.appendingPathComponent(relativePath).standardizedFileURL
            guard url.deletingLastPathComponent() == directory else { continue }
            guard Self.isOwnedProgressPhotoFilename(url.lastPathComponent) else {
                throw FitnessHealthRepositoryError.unsafePath
            }
            referenced.insert(url.lastPathComponent)
        }

        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var enumerationError: Error?
        guard let entries = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw FitnessHealthRepositoryError.unsafePath
        }
        let cutoff = now.addingTimeInterval(-max(0,minimumAge))
        var candidates = 0
        var removed = 0
        while let next = entries.nextObject() {
            try Task.checkCancellation()
            guard candidates < maximumCandidates,removed < maximumRemovals else { break }
            guard let entry = next as? URL else { continue }
            let candidate = entry.standardizedFileURL
            guard candidate.deletingLastPathComponent() == directory,
                  !referenced.contains(candidate.lastPathComponent),
                  Self.isOwnedProgressPhotoArtifactFilename(candidate.lastPathComponent) else {
                continue
            }
            let values = try candidate.resourceValues(forKeys: keys)
            guard
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileDate = values.contentModificationDate ?? values.creationDate,
                  fileDate <= cutoff else { continue }
            candidates += 1
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                fitnessHealthRepositoryLogger.error(
                    "Progress-photo reconciliation could not remove an owned orphan; a later reconciliation will retry: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
        }
        if let enumerationError { throw enumerationError }
        return removed
    }

    func cleanupAcknowledgedProgressPhotoOriginals() throws {
        let assetIds = try database.read { db in
            try String.fetchAll(
                db,sql: """
                    SELECT asset_id FROM fitness_private_file_uploads
                    WHERE upload_acknowledged=1 AND metadata_acknowledged=1
                    """
            )
        }
        for assetId in assetIds { try cleanupAcknowledgedOriginal(assetId: assetId) }
    }

    // MARK: Internal mapping

    private func upsertHealthKitSample(
        _ sample: FitnessHealthKitSample,now: String,db: Database
    ) throws -> String {
        guard sample.domainKind != .sleepSession else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let source = sample.provenance
        let recordKind = domainRecordKind(sample.kind)
        let existing = try Row.fetchOne(
            db,sql: """
                SELECT id,domain_entity_id,sample_type FROM fitness_external_source_records
                WHERE record_kind=? AND transport_key='healthkit'
                  AND source_namespace=? AND source_object_id=?
                """,
            arguments: [recordKind,source.sourceBundleIdentifier,source.sourceObjectId]
        )
        if let priorType: String = existing?["sample_type"],priorType != sample.kind.rawValue {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let entityId: String = existing?["domain_entity_id"] ?? UUID().uuidString
        let sourceId = try upsertHealthKitSource(
            sample,entityId: entityId,existing: existing,now: now,db: db
        )
        switch sample.domainKind {
        case .bodyMeasurement:
            try upsertBodyMeasurement(sample,entityId: entityId,sourceId: sourceId,now: now,db: db)
        case .recoveryObservation:
            try upsertRecovery(sample,entityId: entityId,sourceId: sourceId,now: now,db: db)
        case .sleepSession:
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        return entityId
    }

    @discardableResult
    private func upsertHealthKitSource(
        _ sample: FitnessHealthKitSample,entityId: String,existing: Row?,now: String,db: Database
    ) throws -> String {
        let source = sample.provenance
        let recordKind = domainRecordKind(sample.kind)
        if let priorType: String = existing?["sample_type"],priorType != sample.kind.rawValue {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let sourceId: String = existing?["id"] ?? UUID().uuidString
        try db.execute(
            sql: """
                INSERT INTO fitness_external_source_records
                (id,record_kind,sample_type,transport_key,origin_provider_key,source_namespace,source_object_id,
                 external_object_id,source_device_identifier,source_name,product_type,device_json,
                 metadata_json,domain_entity_type,domain_entity_id,state,created_at,updated_at)
                VALUES (?,?,?,'healthkit',?,?,?,?,?,?,?,?,?,?,?,'active',?,?)
                ON CONFLICT(record_kind,transport_key,source_namespace,source_object_id) DO UPDATE SET
                  sample_type=excluded.sample_type,
                  origin_provider_key=excluded.origin_provider_key,
                  external_object_id=excluded.external_object_id,
                  source_device_identifier=excluded.source_device_identifier,
                  source_name=excluded.source_name,product_type=excluded.product_type,
                  device_json=excluded.device_json,metadata_json=excluded.metadata_json,
                  domain_entity_id=excluded.domain_entity_id,state='active',updated_at=excluded.updated_at
            """,
            arguments: [
                sourceId,recordKind,sample.kind.rawValue,source.originProviderKey,
                source.sourceBundleIdentifier,source.sourceObjectId,source.externalObjectId,
                source.sourceDeviceIdentifier,source.sourceName,source.productType,
                try json(source.device),try json(source.metadata),sample.domainKind.rawValue,
                entityId,now,now,
            ]
        )
        let device = source.device.mapValues(JSONValue.string)
        let payload: [String: JSONValue] = [
            "id": .string(sourceId),"record_kind": .string(recordKind),
            "client_id": .string(try clientId),"client_timestamp": .string(now),
            "sample_type": .string(sample.kind.rawValue),"transport_key": .string("healthkit"),
            "origin_provider_key": .string(source.originProviderKey),
            "source_namespace": .string(source.sourceBundleIdentifier),
            "source_object_id": .string(source.sourceObjectId),
            "external_object_id": source.externalObjectId.map(JSONValue.string) ?? .null,
            "source_device_identifier": source.sourceDeviceIdentifier.map(JSONValue.string) ?? .null,
            "source_name": source.sourceName.map(JSONValue.string) ?? .null,
            "product_type": source.productType.map(JSONValue.string) ?? .null,
            "device_json": .object(device),"metadata_json": .object(source.metadata),
            "domain_entity_type": .string(sample.domainKind.rawValue),
            "domain_entity_id": .string(entityId),"state": .string("active"),
        ]
        try enqueueJSON(db,type: .sourceRecord,id: sourceId,operation: .upsert,payload: payload,now: now)
        return sourceId
    }

    private func upsertBodyMeasurement(
        _ sample: FitnessHealthKitSample,entityId: String,sourceId: String,now: String,db: Database
    ) throws {
        guard let value = sample.value,value.isFinite,value > 0 else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let measured = FitnessDatabase.dateString(sample.startDate)
        let source = sample.provenance
        try db.execute(
            sql: """
                INSERT INTO fitness_body_measurements
                (id,measured_at,weight_kg,source,source_identifier,is_canonical,revision,
                 client_updated_at,origin_device_id,source_record_id,canonical_state,
                 duplicate_of_measurement_id,origin_provider_key,transport_key,source_namespace,
                 external_object_id,measurement_quality,deleted_at,metric_key,value_number,unit_key)
                VALUES (?,?,?,'healthkit',?,1,0,?,'healthkit',?,'canonical',NULL,?,?,?,?,'measured',NULL,
                        'body.weight_kg',?,'kg')
                ON CONFLICT(id) DO UPDATE SET
                  measured_at=excluded.measured_at,weight_kg=excluded.weight_kg,
                  source_identifier=excluded.source_identifier,is_canonical=excluded.is_canonical,
                  client_updated_at=excluded.client_updated_at,source_record_id=excluded.source_record_id,
                  canonical_state=excluded.canonical_state,
                  duplicate_of_measurement_id=excluded.duplicate_of_measurement_id,
                  origin_provider_key=excluded.origin_provider_key,transport_key=excluded.transport_key,
                  source_namespace=excluded.source_namespace,external_object_id=excluded.external_object_id,
                  metric_key='body.weight_kg',value_number=excluded.value_number,unit_key='kg',
                  deleted_at=NULL
                """,
            arguments: [
                entityId,measured,value,"\(source.sourceBundleIdentifier):\(source.sourceObjectId)",
                now,sourceId,source.originProviderKey,"healthkit",source.sourceBundleIdentifier,
                source.externalObjectId,value,
            ]
        )
    }

    private func enqueueBodyMeasurementFromRow(id: String,db: Database,now: String) throws {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM fitness_body_measurements WHERE id=? AND deleted_at IS NULL",
            arguments: [id]
        ) else { return }
        let payload: [String: JSONValue] = [
            "id": .string(id),"metric_key": .string("body.weight_kg"),
            "client_id": .string(try clientId),"client_timestamp": .string(now),
            "measured_at_utc": .string(row["measured_at"]),"local_timezone": .string(TimeZone.current.identifier),
            "value": .double(row["weight_kg"]),"unit_key": .string("kg"),
            "source_record_id": (row["source_record_id"] as String?).map(JSONValue.string) ?? .null,
            "measurement_quality": .string(row["measurement_quality"]),
            "canonical_state": .string(row["canonical_state"]),
            "duplicate_of_measurement_id": (row["duplicate_of_measurement_id"] as String?).map(JSONValue.string) ?? .null,
        ]
        try enqueueJSON(db,type: .bodyMeasurement,id: id,operation: .upsert,payload: payload,now: now)
    }

    private func upsertRecovery(
        _ sample: FitnessHealthKitSample,entityId: String,sourceId: String,now: String,db: Database
    ) throws {
        guard let value = sample.value,value.isFinite,
              sample.kind == .restingHeartRate ? value > 0 : value >= 0 else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let metric = sample.kind == .restingHeartRate ? "recovery.resting_heart_rate_bpm" : "recovery.hrv_sdnn_ms"
        let observed = FitnessDatabase.dateString(sample.startDate)
        let payload: [String: JSONValue] = [
            "id": .string(entityId),"metric_key": .string(metric),"observed_at_utc": .string(observed),
            "client_id": .string(try clientId),"client_timestamp": .string(now),
            "value_number": .double(value),
            "unit_key": sample.unitKey.map(JSONValue.string) ?? .null,
            "source_quality": .string("wearable"),"source_record_id": .string(sourceId),
        ]
        try db.execute(
            sql: """
                INSERT INTO fitness_recovery_observations
                (id,metric_key,observed_at_utc,value_number,unit_key,source_quality,
                 source_record_id,revision,client_updated_at,deleted_at)
                VALUES (?,?,?,?,?,'wearable',?,0,?,NULL)
                ON CONFLICT(id) DO UPDATE SET
                  metric_key=excluded.metric_key,observed_at_utc=excluded.observed_at_utc,
                  value_number=excluded.value_number,unit_key=excluded.unit_key,
                  source_record_id=excluded.source_record_id,client_updated_at=excluded.client_updated_at,
                  deleted_at=NULL
                """,
            arguments: [entityId,metric,observed,value,sample.unitKey,sourceId,now]
        )
        try enqueueJSON(db,type: .recoveryObservation,id: entityId,operation: .upsert,payload: payload,now: now)
    }

    private func applyHealthKitDeletion(
        _ deletion: FitnessHealthKitDeletedObject,now: String,
        affectedSleepSessionIds: inout Set<String>,db: Database
    ) throws {
        let recordKind = domainRecordKind(deletion.kind)
        let sources = try Row.fetchAll(
            db,sql: """
                SELECT * FROM fitness_external_source_records
                WHERE transport_key='healthkit' AND record_kind=? AND sample_type=?
                  AND source_object_id=? AND state='active'
                """,
            arguments: [recordKind,deletion.kind.rawValue,deletion.sourceObjectId]
        )
        for source in sources {
            let sourceId: String = source["id"]
            let entityId: String = source["domain_entity_id"]
            let entityType: String = source["domain_entity_type"]
            try db.execute(sql: "UPDATE fitness_external_source_records SET state='deleted',updated_at=? WHERE id=?",arguments: [now,sourceId])
            try enqueueSourceRecord(id: sourceId,operation: .delete,now: now,db: db)
            if deletion.kind == .sleepAnalysis {
                affectedSleepSessionIds.insert(entityId)
                try db.execute(
                    sql: "UPDATE fitness_sleep_segments SET deleted_at=? WHERE source_record_id=?",
                    arguments: [now,sourceId]
                )
                continue
            }
            let table: String
            let type: FitnessEntityType
            switch entityType {
            case FitnessEntityType.bodyMeasurement.rawValue: table = "fitness_body_measurements"; type = .bodyMeasurement
            case FitnessEntityType.sleepSession.rawValue: table = "fitness_sleep_sessions"; type = .sleepSession
            case FitnessEntityType.recoveryObservation.rawValue: table = "fitness_recovery_observations"; type = .recoveryObservation
            default: continue
            }
            try db.execute(sql: "UPDATE \(table) SET deleted_at=?,client_updated_at=? WHERE id=?",arguments: [now,now,entityId])
            try enqueueJSON(
                db,type: type,id: entityId,operation: .delete,payload: [:],now: now
            )
        }
    }

    private func sourceDTO(joinedRow row: Row) -> FitnessExternalSourceDTO? {
        guard let transport:String=row["detail_transport_key"],
              let provider:String=row["detail_origin_provider_key"],
              let namespace:String=row["detail_source_namespace"] else { return nil }
        return FitnessExternalSourceDTO(
            transportKey:transport,originProviderKey:provider,sourceNamespace:namespace,
            sourceDeviceIdentifier:row["detail_source_device_identifier"],
            state:row["detail_source_state"]
        )
    }

    // HealthKit exposes sleep stages as individual category samples. Keep those
    // exact source records, but normalize connected nightly stages into one
    // session for the domain/API contract.
    private struct SleepSegment {
        var sourceRecordId: String
        var sessionId: String
        var originProviderKey: String
        var sourceNamespace: String
        var stage: String
        var start: Date
        var end: Date
        var startString: String
        var endString: String
        var duration: Double
    }

    private func upsertHealthKitSleepSegment(
        _ sample: FitnessHealthKitSample,now: String,
        affectedSessionIds: inout Set<String>,db: Database
    ) throws {
        guard sample.kind == .sleepAnalysis,sample.domainKind == .sleepSession,
              sample.endDate > sample.startDate,
              sample.endDate.timeIntervalSince(sample.startDate) <= 48 * 3_600,
              ["in_bed","awake","asleep","core","deep","rem"].contains(sample.sleepStage ?? "asleep") else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let source = sample.provenance
        let existing = try Row.fetchOne(
            db,sql: """
                SELECT id,domain_entity_id,sample_type FROM fitness_external_source_records
                WHERE record_kind=? AND transport_key='healthkit'
                  AND source_namespace=? AND source_object_id=?
                """,
            arguments: [FitnessEntityType.sleepSession.rawValue,source.sourceBundleIdentifier,source.sourceObjectId]
        )
        if let priorType: String = existing?["sample_type"],priorType != sample.kind.rawValue {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let existingSessionId: String? = existing?["domain_entity_id"]
        let gap: TimeInterval = 30 * 60
        let candidates = try Row.fetchAll(
            db,sql: """
                SELECT session_id,start_at_utc,end_at_utc FROM fitness_sleep_segments
                WHERE origin_provider_key=? AND deleted_at IS NULL
                  AND start_at_utc<=? AND end_at_utc>=?
                """,arguments: [
                    source.originProviderKey,
                    FitnessDatabase.dateString(sample.endDate.addingTimeInterval(gap)),
                    FitnessDatabase.dateString(sample.startDate.addingTimeInterval(-gap)),
                ]
        ).compactMap { row -> String? in
            guard let start = FitnessDatabase.date(row["start_at_utc"]),
                  let end = FitnessDatabase.date(row["end_at_utc"]) else { return nil }
            guard start <= sample.endDate.addingTimeInterval(gap),
                  end >= sample.startDate.addingTimeInterval(-gap) else { return nil }
            return row["session_id"]
        }
        var connected = Set(candidates)
        if let existingSessionId { connected.insert(existingSessionId) }
        let sessionId = existingSessionId ?? connected.sorted().first ?? UUID().uuidString
        for mergedId in connected where mergedId != sessionId {
            affectedSessionIds.insert(mergedId)
            try moveSleepSegments(from: mergedId,to: sessionId,now: now,db: db)
            try tombstoneSleepSession(id: mergedId,now: now,db: db)
        }
        let sourceId = try upsertHealthKitSource(
            sample,entityId: sessionId,existing: existing,now: now,db: db
        )
        try db.execute(
            sql: """
                INSERT INTO fitness_sleep_segments
                (source_record_id,session_id,origin_provider_key,source_namespace,stage,
                 start_at_utc,end_at_utc,duration_s,deleted_at)
                VALUES (?,?,?,?,?,?,?,?,NULL)
                ON CONFLICT(source_record_id) DO UPDATE SET
                  session_id=excluded.session_id,origin_provider_key=excluded.origin_provider_key,
                  source_namespace=excluded.source_namespace,stage=excluded.stage,
                  start_at_utc=excluded.start_at_utc,end_at_utc=excluded.end_at_utc,
                  duration_s=excluded.duration_s,deleted_at=NULL
                """,
            arguments: [
                sourceId,sessionId,source.originProviderKey,source.sourceBundleIdentifier,
                sample.sleepStage ?? "asleep",FitnessDatabase.dateString(sample.startDate),
                FitnessDatabase.dateString(sample.endDate),sample.endDate.timeIntervalSince(sample.startDate),
            ]
        )
        affectedSessionIds.insert(sessionId)
    }

    private func moveSleepSegments(from oldId: String,to newId: String,now: String,db: Database) throws {
        let sourceIds = try String.fetchAll(
            db,sql: "SELECT source_record_id FROM fitness_sleep_segments WHERE session_id=? AND deleted_at IS NULL",
            arguments: [oldId]
        )
        try db.execute(
            sql: "UPDATE fitness_sleep_segments SET session_id=? WHERE session_id=? AND deleted_at IS NULL",
            arguments: [newId,oldId]
        )
        for sourceId in sourceIds {
            try db.execute(
                sql: "UPDATE fitness_external_source_records SET domain_entity_id=?,updated_at=? WHERE id=?",
                arguments: [newId,now,sourceId]
            )
            try enqueueSourceRecord(id: sourceId,operation: .upsert,now: now,db: db)
        }
    }

    private func rebuildSleepSessions(_ ids: Set<String>,now: String,db: Database) throws {
        for id in ids.sorted() { try rebuildSleepSession(id: id,now: now,db: db) }
    }

    private func rebuildSleepSession(id: String,now: String,db: Database) throws {
        let segments = try sleepSegments(sessionId: id,db: db)
        guard !segments.isEmpty else {
            try tombstoneSleepSession(id: id,now: now,db: db)
            return
        }
        let groups = connectedSleepGroups(segments)
        for (index,group) in groups.enumerated() {
            let groupId = index == 0 ? id : UUID().uuidString
            if groupId != id {
                for segment in group {
                    try db.execute(
                        sql: "UPDATE fitness_sleep_segments SET session_id=? WHERE source_record_id=?",
                        arguments: [groupId,segment.sourceRecordId]
                    )
                    try db.execute(
                        sql: "UPDATE fitness_external_source_records SET domain_entity_id=?,updated_at=? WHERE id=?",
                        arguments: [groupId,now,segment.sourceRecordId]
                    )
                    try enqueueSourceRecord(id: segment.sourceRecordId,operation: .upsert,now: now,db: db)
                }
            }
            try writeSleepSession(id: groupId,segments: group,now: now,db: db)
        }
    }

    private func sleepSegments(sessionId: String,db: Database) throws -> [SleepSegment] {
        try Row.fetchAll(
            db,sql: """
                SELECT * FROM fitness_sleep_segments
                WHERE session_id=? AND deleted_at IS NULL ORDER BY start_at_utc,end_at_utc,source_record_id
                """,arguments: [sessionId]
        ).map { row in
            let startString: String = row["start_at_utc"]
            let endString: String = row["end_at_utc"]
            guard let start = FitnessDatabase.date(startString),let end = FitnessDatabase.date(endString) else {
                throw FitnessHealthRepositoryError.invalidHealthKitSample
            }
            return SleepSegment(
                sourceRecordId: row["source_record_id"],sessionId: row["session_id"],
                originProviderKey: row["origin_provider_key"],sourceNamespace: row["source_namespace"],
                stage: row["stage"],start: start,end: end,startString: startString,endString: endString,
                duration: row["duration_s"]
            )
        }
    }

    private func connectedSleepGroups(_ segments: [SleepSegment]) -> [[SleepSegment]] {
        let ordered = segments.sorted {
            $0.start == $1.start ? $0.sourceRecordId < $1.sourceRecordId : $0.start < $1.start
        }
        var groups: [[SleepSegment]] = []
        var current: [SleepSegment] = []
        var currentEnd: Date?
        for segment in ordered {
            if let end = currentEnd,segment.start > end.addingTimeInterval(30 * 60) {
                groups.append(current)
                current = []
                currentEnd = nil
            }
            current.append(segment)
            currentEnd = max(currentEnd ?? segment.end,segment.end)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private func writeSleepSession(
        id: String,segments: [SleepSegment],now: String,db: Database
    ) throws {
        guard let start = segments.map(\.start).min(),let end = segments.map(\.end).max(),
              let primary = segments.sorted(by: { $0.start < $1.start }).first else { return }
        let asleep = segments.filter { $0.stage != "awake" && $0.stage != "in_bed" }
        let awake = unionDuration(segments.filter { $0.stage == "awake" })
        let sleepDuration = asleep.isEmpty
            ? max(0,end.timeIntervalSince(start) - awake)
            : unionDuration(asleep)
        let stages = segments.sorted { $0.start < $1.start }.map {
            FitnessSleepStageDTO(
                stage: $0.stage,startAtUtc: $0.startString,endAtUtc: $0.endString,
                durationS: $0.duration,sourceRecordId: $0.sourceRecordId
            )
        }
        let startString = FitnessDatabase.dateString(start)
        let endString = FitnessDatabase.dateString(end)
        let payload: [String: JSONValue] = [
            "id": .string(id),"sleep_start_utc": .string(startString),
            "client_id": .string(try clientId),"client_timestamp": .string(now),
            "sleep_end_utc": .string(endString),"duration_s": .double(sleepDuration),
            "awake_duration_s": .double(awake),"source_quality": .string("wearable"),
            "source_record_id": .string(primary.sourceRecordId),
            "source_stages": .array(stages.map { stage in .object([
                "stage": .string(stage.stage),"start_at_utc": .string(stage.startAtUtc),
                "end_at_utc": .string(stage.endAtUtc),"duration_s": .double(stage.durationS),
                "source_record_id": stage.sourceRecordId.map(JSONValue.string) ?? .null,
            ]) }),
        ]
        try db.execute(
            sql: """
                INSERT INTO fitness_sleep_sessions
                (id,sleep_start_utc,sleep_end_utc,duration_s,awake_duration_s,source_quality,
                 source_stages_json,source_record_id,revision,client_updated_at,deleted_at,payload_json)
                VALUES (?,?,?,?,?,'wearable',?,?,0,?,NULL,?)
                ON CONFLICT(id) DO UPDATE SET
                  sleep_start_utc=excluded.sleep_start_utc,sleep_end_utc=excluded.sleep_end_utc,
                  duration_s=excluded.duration_s,awake_duration_s=excluded.awake_duration_s,
                  source_stages_json=excluded.source_stages_json,source_record_id=excluded.source_record_id,
                  client_updated_at=excluded.client_updated_at,deleted_at=NULL,payload_json=excluded.payload_json
                """,
            arguments: [id,startString,endString,sleepDuration,awake,try json(stages),primary.sourceRecordId,now,try json(payload)]
        )
        try enqueueJSON(db,type: .sleepSession,id: id,operation: .upsert,payload: payload,now: now)
    }

    private func unionDuration(_ segments: [SleepSegment]) -> Double {
        let ordered = segments.sorted { $0.start < $1.start }
        guard var start = ordered.first?.start,var end = ordered.first?.end else { return 0 }
        var total: TimeInterval = 0
        for segment in ordered.dropFirst() {
            if segment.start <= end { end = max(end,segment.end) }
            else {
                total += end.timeIntervalSince(start)
                start = segment.start
                end = segment.end
            }
        }
        return total + end.timeIntervalSince(start)
    }

    private func tombstoneSleepSession(id: String,now: String,db: Database) throws {
        guard try Bool.fetchOne(
            db,sql: "SELECT deleted_at IS NULL FROM fitness_sleep_sessions WHERE id=?",arguments: [id]
        ) == true else { return }
        try db.execute(
            sql: "UPDATE fitness_sleep_sessions SET deleted_at=?,client_updated_at=? WHERE id=?",
            arguments: [now,now,id]
        )
        try enqueueJSON(
            db,type: .sleepSession,id: id,operation: .delete,payload: [:],now: now
        )
    }

    private struct WeightSourceRow {
        var id: String
        var provider: String
        var transport: String
        var namespace: String
        var externalId: String?
        var value: Double
        var measuredAt: Date
        var manualCanonicalOverride: Bool
        var isCanonical: Bool
        var duplicateOfMeasurementId: String?
    }

    private struct WeightPriorityRow {
        let provider: String
        let transport: String
        let namespace: String
        let priority: Int
    }

    private struct WeightDisjointSet {
        private var parent: [Int]
        private var rank: [UInt8]

        init(count: Int) {
            parent = Array(0..<count)
            rank = Array(repeating: 0,count: count)
        }

        mutating func root(of value: Int) -> Int {
            var current = value
            while parent[current] != current { current = parent[current] }
            let root = current
            current = value
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }

        mutating func join(_ lhs: Int,_ rhs: Int) {
            let left = root(of: lhs)
            let right = root(of: rhs)
            guard left != right else { return }
            if rank[left] < rank[right] { parent[left] = right }
            else if rank[left] > rank[right] { parent[right] = left }
            else {
                parent[right] = left
                rank[left] &+= 1
            }
        }
    }

    /// One value bucket spans the duplicate tolerance. All entries that remain
    /// in the two-minute active window of the same bucket are mutually
    /// connected, so a representative plus the boundary extrema are sufficient;
    /// dense weigh-in bursts do not degrade back to pairwise O(n^2) work.
    private final class ActiveWeightBucket {
        private var ordered: [Int] = []
        private var orderedHead = 0
        private var minima: [Int] = []
        private var minimaHead = 0
        private var maxima: [Int] = []
        private var maximaHead = 0

        func evict(before cutoff: Date,rows: [WeightSourceRow]) {
            while orderedHead < ordered.count,
                  rows[ordered[orderedHead]].measuredAt < cutoff { orderedHead += 1 }
            while minimaHead < minima.count,
                  rows[minima[minimaHead]].measuredAt < cutoff { minimaHead += 1 }
            while maximaHead < maxima.count,
                  rows[maxima[maximaHead]].measuredAt < cutoff { maximaHead += 1 }
        }

        func insert(_ index: Int,rows: [WeightSourceRow]) {
            ordered.append(index)
            while minima.count > minimaHead,
                  let last = minima.last,
                  rows[last].value > rows[index].value { minima.removeLast() }
            minima.append(index)
            while maxima.count > maximaHead,
                  let last = maxima.last,
                  rows[last].value < rows[index].value { maxima.removeLast() }
            maxima.append(index)
        }

        var representative: Int? { orderedHead < ordered.count ? ordered[orderedHead] : nil }
        var minimum: Int? { minimaHead < minima.count ? minima[minimaHead] : nil }
        var maximum: Int? { maximaHead < maxima.count ? maxima[maximaHead] : nil }
        var isEmpty: Bool { representative == nil }
    }

    /// Reranks only graph components reachable from the readings changed by the
    /// current anchored HealthKit page. Before this path loaded every weight row
    /// and repeatedly filtered an unvisited set (full-table O(n^2)). The frontier
    /// reads use the provider/time/value and provider/external-id indexes, then a
    /// deterministic bucket sweep + union-find ranks only the affected rows.
    private func rerankWeightGroups(
        affectedBy seeds: [WeightSourceRow],now: String,db: Database
    ) throws -> Set<String> {
        guard !seeds.isEmpty else { return [] }
        let values = try affectedWeightRows(seeds: seeds,db: db)
        guard !values.isEmpty else { return [] }
        let providers = Array(Set(values.map(\.provider))).sorted()
        let placeholders = Array(repeating: "?",count: providers.count).joined(separator: ",")
        let priorityRows = try Row.fetchAll(
            db,sql: """
                SELECT origin_provider_key,transport_key,source_namespace,priority
                FROM fitness_source_priorities
                WHERE metric_key='body.weight_kg' AND deleted_at IS NULL
                  AND origin_provider_key IN (\(placeholders))
                ORDER BY origin_provider_key,
                         (transport_key <> '') + (source_namespace <> '') DESC,
                         priority DESC,transport_key,source_namespace
                """,
            arguments: StatementArguments(providers)
        ).map {
            WeightPriorityRow(
                provider: $0["origin_provider_key"],transport: $0["transport_key"],
                namespace: $0["source_namespace"],priority: $0["priority"]
            )
        }
        func priority(for row: WeightSourceRow) -> Int {
            let match = priorityRows.first { configured in
                configured.provider == row.provider
                    && (configured.transport.isEmpty || configured.transport == row.transport)
                    && (configured.namespace.isEmpty || configured.namespace == row.namespace)
            }
            return match?.priority ?? (row.transport == "healthkit" ? 50 : 100)
        }

        var changedIds = Set<String>()
        for providerRows in Dictionary(grouping: values,by: \.provider).values {
            let rows = providerRows.sorted {
                $0.measuredAt == $1.measuredAt ? $0.id < $1.id : $0.measuredAt < $1.measuredAt
            }
            var groups = WeightDisjointSet(count: rows.count)
            var firstExternalId: [String: Int] = [:]
            var activeBuckets: [Int: ActiveWeightBucket] = [:]
            let bucketWidth = 0.05
            for (index,row) in rows.enumerated() {
                if let externalId = row.externalId,!externalId.isEmpty {
                    if let first = firstExternalId[externalId] { groups.join(index,first) }
                    else { firstExternalId[externalId] = index }
                }
                let bucketKey = Int(floor(row.value / bucketWidth))
                let cutoff = row.measuredAt.addingTimeInterval(-120)
                // Include one extra bucket on either edge for binary floating-
                // point values that land infinitesimally across an exact 0.05
                // boundary; `sameWeightReading` remains the final predicate.
                for nearbyKey in (bucketKey - 2)...(bucketKey + 2) {
                    guard let bucket = activeBuckets[nearbyKey] else { continue }
                    bucket.evict(before: cutoff,rows: rows)
                    if bucket.isEmpty {
                        activeBuckets.removeValue(forKey: nearbyKey)
                        continue
                    }
                    let candidate: Int? = if nearbyKey < bucketKey {
                        bucket.maximum
                    } else if nearbyKey > bucketKey {
                        bucket.minimum
                    } else {
                        bucket.representative
                    }
                    if let candidate,sameWeightReading(row,rows[candidate]) {
                        groups.join(index,candidate)
                    }
                }
                let bucket = activeBuckets[bucketKey] ?? ActiveWeightBucket()
                bucket.insert(index,rows: rows)
                activeBuckets[bucketKey] = bucket
            }

            var components: [Int: [WeightSourceRow]] = [:]
            for (index,row) in rows.enumerated() {
                components[groups.root(of: index),default: []].append(row)
            }
            for component in components.values {
                let ranked = component.map { ($0,priority(for: $0)) }.sorted {
                    if $0.0.manualCanonicalOverride != $1.0.manualCanonicalOverride {
                        return $0.0.manualCanonicalOverride
                    }
                    if $0.1 != $1.1 { return $0.1 > $1.1 }
                    if ($0.0.transport == "healthkit") != ($1.0.transport == "healthkit") {
                        return $0.0.transport != "healthkit"
                    }
                    return $0.0.id < $1.0.id
                }
                guard let canonicalId = ranked.first?.0.id else { continue }
                for (member,_) in ranked {
                    let isCanonical = member.id == canonicalId
                    let duplicateId: String? = isCanonical ? nil : canonicalId
                    guard member.isCanonical != isCanonical
                            || member.duplicateOfMeasurementId != duplicateId else { continue }
                    try db.execute(
                        sql: """
                            UPDATE fitness_body_measurements SET is_canonical=?,canonical_state=?,
                              duplicate_of_measurement_id=?,client_updated_at=? WHERE id=?
                            """,
                        arguments: [isCanonical,isCanonical ? "canonical" : "duplicate",
                                    duplicateId,now,member.id]
                    )
                    changedIds.insert(member.id)
                }
            }
        }
        return changedIds
    }

    private func affectedWeightRows(
        seeds: [WeightSourceRow],db: Database
    ) throws -> [WeightSourceRow] {
        // Each query carries at most 48 indexed windows, keeping SQLite's
        // statement/parameter size fixed even for a long transitive chain.
        let frontierLimit = 48
        var frontier = seeds
        var discovered: [String: WeightSourceRow] = [:]
        while !frontier.isEmpty {
            var next: [WeightSourceRow] = []
            for start in stride(from: 0,to: frontier.count,by: frontierLimit) {
                let batch = Array(frontier[start..<min(start + frontierLimit,frontier.count)])
                var conditions: [String] = []
                var arguments: StatementArguments = []
                for seed in batch {
                    var matches = ["(measured_at BETWEEN ? AND ? AND weight_kg BETWEEN ? AND ?)"]
                    var seedArguments = StatementArguments([seed.provider])
                    seedArguments += [
                        FitnessDatabase.dateString(seed.measuredAt.addingTimeInterval(-120)),
                        FitnessDatabase.dateString(seed.measuredAt.addingTimeInterval(120)),
                        seed.value - 0.05,seed.value + 0.05,
                    ]
                    if let externalId = seed.externalId,!externalId.isEmpty {
                        matches.append("external_object_id=?")
                        seedArguments += [externalId]
                    }
                    conditions.append("(origin_provider_key=? AND (\(matches.joined(separator: " OR "))))")
                    arguments += seedArguments
                }
                let rows = try Row.fetchAll(
                    db,sql: """
                        SELECT id,origin_provider_key,transport_key,source_namespace,
                               external_object_id,weight_kg,measured_at,
                               manual_canonical_override,is_canonical,duplicate_of_measurement_id
                        FROM fitness_body_measurements
                        WHERE metric_key='body.weight_kg' AND deleted_at IS NULL
                          AND origin_provider_key IS NOT NULL
                          AND (\(conditions.joined(separator: " OR ")))
                        ORDER BY origin_provider_key,measured_at,id
                        """,arguments: arguments
                ).map(weightRow)
                for row in rows where discovered[row.id] == nil {
                    discovered[row.id] = row
                    next.append(row)
                }
            }
            frontier = next
        }
        return Array(discovered.values)
    }

    private func weightRow(id: String,db: Database) throws -> WeightSourceRow? {
        try Row.fetchOne(
            db,sql: """
                SELECT id,origin_provider_key,transport_key,source_namespace,
                       external_object_id,weight_kg,measured_at,
                       manual_canonical_override,is_canonical,duplicate_of_measurement_id
                FROM fitness_body_measurements
                WHERE id=? AND metric_key='body.weight_kg' AND deleted_at IS NULL
                  AND origin_provider_key IS NOT NULL
                """,arguments: [id]
        ).map(weightRow)
    }

    private func weightRow(for sample: FitnessHealthKitSample,db: Database) throws -> WeightSourceRow? {
        let source = sample.provenance
        return try Row.fetchOne(
            db,sql: """
                SELECT m.id,m.origin_provider_key,m.transport_key,m.source_namespace,
                       m.external_object_id,m.weight_kg,m.measured_at,
                       m.manual_canonical_override,m.is_canonical,m.duplicate_of_measurement_id
                FROM fitness_external_source_records s
                JOIN fitness_body_measurements m ON m.id=s.domain_entity_id
                WHERE s.record_kind=? AND s.transport_key='healthkit'
                  AND s.source_namespace=? AND s.source_object_id=?
                  AND m.metric_key='body.weight_kg'
                LIMIT 1
                """,arguments: [
                    domainRecordKind(sample.kind),source.sourceBundleIdentifier,source.sourceObjectId,
                ]
        ).map(weightRow)
    }

    private func weightRows(
        for deletion: FitnessHealthKitDeletedObject,db: Database
    ) throws -> [WeightSourceRow] {
        try Row.fetchAll(
            db,sql: """
                SELECT m.id,m.origin_provider_key,m.transport_key,m.source_namespace,
                       m.external_object_id,m.weight_kg,m.measured_at,
                       m.manual_canonical_override,m.is_canonical,m.duplicate_of_measurement_id
                FROM fitness_external_source_records s
                JOIN fitness_body_measurements m ON m.id=s.domain_entity_id
                WHERE s.record_kind=? AND s.transport_key='healthkit'
                  AND s.sample_type=? AND s.source_object_id=? AND s.state='active'
                  AND m.metric_key='body.weight_kg'
                """,arguments: [
                    domainRecordKind(deletion.kind),deletion.kind.rawValue,deletion.sourceObjectId,
                ]
        ).map(weightRow)
    }

    private func weightRow(_ row: Row) throws -> WeightSourceRow {
        guard let measured = FitnessDatabase.date(row["measured_at"]),
              let provider: String = row["origin_provider_key"] else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        return WeightSourceRow(
            id: row["id"],provider: provider,
            transport: (row["transport_key"] as String?) ?? "direct",
            namespace: (row["source_namespace"] as String?) ?? "",
            externalId: row["external_object_id"],value: row["weight_kg"],measuredAt: measured,
            manualCanonicalOverride: (row["manual_canonical_override"] as Int? ?? 0) != 0,
            isCanonical: (row["is_canonical"] as Int) != 0,
            duplicateOfMeasurementId: row["duplicate_of_measurement_id"]
        )
    }

    private func sameWeightReading(_ lhs: WeightSourceRow,_ rhs: WeightSourceRow) -> Bool {
        guard lhs.provider == rhs.provider else { return false }
        if let left = lhs.externalId,let right = rhs.externalId,left == right { return true }
        return abs(lhs.value - rhs.value) <= 0.05
            && abs(lhs.measuredAt.timeIntervalSince(rhs.measuredAt)) <= 120
    }

    private struct WorkoutOutboxRecord {
        let id: String
        let kind: FitnessHealthKitWorkoutOutboxItem.Kind
        let workoutUuid: String
        let sourceBundleIdentifier: String?
        let payload: String
        let createdAt: String

        var payloadByteCount: Int { payload.utf8.count }
    }

    private func workoutOutboxRecord(
        request: FitnessHealthKitWorkoutImport,now: String
    ) throws -> WorkoutOutboxRecord {
        guard Self.validWorkoutRequest(request) else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        let payload = try json(request)
        guard payload.utf8.count <= FitnessHealthKitWorkoutOutboxPolicy.maximumPayloadBytes else {
            throw FitnessHealthRepositoryError.invalidHealthKitSample
        }
        return WorkoutOutboxRecord(
            id: Self.workoutMutationID(request: request),kind: .import,
            workoutUuid: request.workoutUuid,
            sourceBundleIdentifier: request.sourceBundleIdentifier,
            payload: payload,createdAt: now
        )
    }

    private static func workoutDeletionResolverRecord(
        workoutUuid: String,now: String
    ) -> WorkoutOutboxRecord {
        WorkoutOutboxRecord(
            id: workoutResolverMutationID(workoutUuid: workoutUuid),kind: .resolveDelete,
            workoutUuid: workoutUuid,sourceBundleIdentifier: nil,payload: "{}",createdAt: now
        )
    }

    private func upsertWorkoutOutbox(_ record: WorkoutOutboxRecord,db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_healthkit_workout_outbox
                (mutation_id,mutation_kind,workout_uuid,source_bundle_identifier,
                 payload_json,payload_byte_count,state,attempt_count,created_at,updated_at,
                 last_attempt_at,last_error)
                VALUES (?,?,?,?,?,?,'pending',0,?,?,NULL,NULL)
                ON CONFLICT(mutation_id) DO UPDATE SET
                  mutation_kind=excluded.mutation_kind,workout_uuid=excluded.workout_uuid,
                  source_bundle_identifier=excluded.source_bundle_identifier,
                  payload_json=excluded.payload_json,
                  payload_byte_count=excluded.payload_byte_count,state='pending',
                  attempt_count=0,created_at=excluded.created_at,updated_at=excluded.updated_at,
                  last_attempt_at=NULL,last_error=NULL
                """,
            arguments: [
                record.id,record.kind.rawValue,record.workoutUuid,
                record.sourceBundleIdentifier,record.payload,record.payloadByteCount,
                record.createdAt,record.createdAt,
            ]
        )
    }

    private func ensureWorkoutOutboxCapacity(
        adding records: [WorkoutOutboxRecord],removing ids: Set<String>,db: Database
    ) throws {
        let totals = try Row.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) AS row_count,COALESCE(SUM(payload_byte_count),0) AS byte_count
                FROM fitness_healthkit_workout_outbox
                """
        )
        var rowCount: Int = totals?["row_count"] ?? 0
        var byteCount: Int = totals?["byte_count"] ?? 0
        for id in ids {
            if let existing = try Int.fetchOne(
                db,
                sql: "SELECT payload_byte_count FROM fitness_healthkit_workout_outbox WHERE mutation_id=?",
                arguments: [id]
            ) {
                rowCount -= 1
                byteCount -= existing
            }
        }
        for record in records {
            let existing: Int? = ids.contains(record.id) ? nil : try Int.fetchOne(
                db,
                sql: "SELECT payload_byte_count FROM fitness_healthkit_workout_outbox WHERE mutation_id=?",
                arguments: [record.id]
            )
            if let existing {
                byteCount -= existing
            } else {
                rowCount += 1
            }
            byteCount += record.payloadByteCount
        }
        guard rowCount <= FitnessHealthKitWorkoutOutboxPolicy.maximumRows,
              byteCount <= FitnessHealthKitWorkoutOutboxPolicy.maximumBytes else {
            throw FitnessHealthRepositoryError.healthKitWorkoutOutboxFull
        }
    }

    static func workoutMutationID(request: FitnessHealthKitWorkoutImport) -> String {
        workoutMutationID(
            workoutUuid: request.workoutUuid,
            sourceBundleIdentifier: request.sourceBundleIdentifier
        )
    }

    static func workoutMutationID(
        workoutUuid: String,sourceBundleIdentifier: String
    ) -> String {
        "hk-workout-v1-" + stableDigest(
            "import\u{0}\(workoutUuid.lowercased())\u{0}\(sourceBundleIdentifier)"
        )
    }

    static func workoutResolverMutationID(workoutUuid: String) -> String {
        "hk-workout-resolve-v1-" + stableDigest("resolve-delete\u{0}\(workoutUuid.lowercased())")
    }

    private static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x",$0) }.joined()
    }

    private static func validSourceIdentity(bundle: String,provider: String) -> Bool {
        !bundle.isEmpty && bundle.count <= 300 && !provider.isEmpty && provider.count <= 80
    }

    private static func validWorkoutRequest(_ request: FitnessHealthKitWorkoutImport) -> Bool {
        guard UUID(uuidString: request.workoutUuid) != nil,
              validSourceIdentity(
                  bundle: request.sourceBundleIdentifier,provider: request.originProviderKey
              ),
              request.externalUuid.map({ !$0.isEmpty && $0.count <= 500 }) ?? true,
              request.sourceName.map({ !$0.isEmpty && $0.count <= 200 }) ?? true,
              request.sourceDeviceIdentifier.map({ !$0.isEmpty && $0.count <= 300 }) ?? true,
              request.productType.map({ !$0.isEmpty && $0.count <= 200 }) ?? true else {
            return false
        }
        if request.deleted { return true }
        guard let sport = request.sportKey,!sport.isEmpty,sport.count <= 80,
              request.subSportKey.map({ !$0.isEmpty && $0.count <= 80 }) ?? true,
              request.title.map({ !$0.isEmpty && $0.count <= 200 }) ?? true,
              let startString = request.startedAtUtc,
              let endString = request.endedAtUtc,
              let start = FitnessDatabase.date(startString),
              let end = FitnessDatabase.date(endString),end > start,
              let duration = request.durationS,duration.isFinite,duration > 0,
              duration <= 604_800,duration <= end.timeIntervalSince(start) + 2,
              request.distanceM.map({ $0.isFinite && $0 >= 0 && $0 <= 2_000_000 }) ?? true,
              request.energyKcal.map({ $0.isFinite && $0 >= 0 && $0 <= 100_000 }) ?? true,
              let timezone = request.localTimezone,timezone.count <= 100,
              TimeZone(identifier: timezone) != nil else { return false }
        return true
    }

    private static func validWorkoutAcknowledgement(
        request: FitnessHealthKitWorkoutImport,response: FitnessHealthKitWorkoutImportResponse
    ) -> Bool {
        guard !response.sourceRecordId.isEmpty,response.sourceRecordId.count <= 300,
              response.activityId.map({ !$0.isEmpty && $0.count <= 300 }) ?? true else {
            return false
        }
        if request.deleted {
            return response.deleted && ["deleted","already_deleted"].contains(response.status)
        }
        return !response.deleted && ["created","updated","unchanged"].contains(response.status)
    }

    private func enqueueSourceRecord(
        id: String,operation: FitnessMutationOperation,now: String,db: Database
    ) throws {
        if operation == .delete {
            try enqueueJSON(db,type: .sourceRecord,id: id,operation: .delete,payload: [:],now: now)
            return
        }
        guard let row = try Row.fetchOne(
            db,sql: "SELECT * FROM fitness_external_source_records WHERE id=?",arguments: [id]
        ) else { return }
        let device: [String: JSONValue] = try decodeJSON(row["device_json"] as String?) ?? [:]
        let metadata: [String: JSONValue] = try decodeJSON(row["metadata_json"] as String?) ?? [:]
        let payload: [String: JSONValue] = [
            "id": .string(id),"record_kind": .string(row["record_kind"]),
            "client_id": .string(try clientId),"client_timestamp": .string(now),
            "sample_type": .string(row["sample_type"]),"transport_key": .string(row["transport_key"]),
            "origin_provider_key": .string(row["origin_provider_key"]),
            "source_namespace": .string(row["source_namespace"]),
            "source_object_id": .string(row["source_object_id"]),
            "external_object_id": (row["external_object_id"] as String?).map(JSONValue.string) ?? .null,
            "source_device_identifier": (row["source_device_identifier"] as String?).map(JSONValue.string) ?? .null,
            "source_name": (row["source_name"] as String?).map(JSONValue.string) ?? .null,
            "product_type": (row["product_type"] as String?).map(JSONValue.string) ?? .null,
            "device_json": .object(device),"metadata_json": .object(metadata),
            "domain_entity_type": .string(row["domain_entity_type"]),
            "domain_entity_id": .string(row["domain_entity_id"]),"state": .string(row["state"]),
        ]
        try enqueueJSON(db,type: .sourceRecord,id: id,operation: operation,payload: payload,now: now)
    }

    private func domainRecordKind(_ kind: FitnessHealthKitSampleKind) -> String {
        switch kind {
        case .workout: "activity"
        case .bodyMass: FitnessEntityType.bodyMeasurement.rawValue
        case .sleepAnalysis: FitnessEntityType.sleepSession.rawValue
        case .restingHeartRate,.heartRateVariabilitySDNN: "recovery_metric"
        }
    }

    private func enqueue<T: Encodable>(
        _ db: Database,type: FitnessEntityType,id: String,operation: FitnessMutationOperation,
        payload: T,now: Date
    ) throws {
        let data = try encoder.encode(payload)
        let object = try decoder.decode([String: JSONValue].self,from: data)
        try enqueueJSON(db,type: type,id: id,operation: operation,payload: object,now: FitnessDatabase.dateString(now))
    }

    private func enqueueJSON(
        _ db: Database,type: FitnessEntityType,id: String,operation: FitnessMutationOperation,
        payload: [String: JSONValue],now: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_outbox
                (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                 base_revision,payload_json,created_at_client)
                VALUES (?,?,?,?,1,NULL,?,?)
                """,
            arguments: [UUID().uuidString,type.rawValue,id,operation.rawValue,try json(payload),now]
        )
    }

    private func upsertProgressPhoto(_ photo: FitnessProgressPhotoDTO,db: Database) throws {
        let now = photo.updatedAt ?? FitnessDatabase.dateString(Date())
        try db.execute(
            sql: """
                INSERT INTO fitness_progress_photos
                (id,captured_at,pose,body_weight_kg,measurement_snapshot_json,phase_id,phase_name,
                 original_asset_id,thumbnail_asset_id,original_state,thumbnail_state,notes,
                 metadata_acknowledged,revision,client_updated_at,deleted_at,payload_json)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  captured_at=excluded.captured_at,pose=excluded.pose,body_weight_kg=excluded.body_weight_kg,
                  measurement_snapshot_json=excluded.measurement_snapshot_json,phase_id=excluded.phase_id,
                  phase_name=excluded.phase_name,original_asset_id=excluded.original_asset_id,
                  thumbnail_asset_id=excluded.thumbnail_asset_id,original_state=excluded.original_state,
                  thumbnail_state=excluded.thumbnail_state,notes=excluded.notes,
                  metadata_acknowledged=excluded.metadata_acknowledged,revision=excluded.revision,
                  client_updated_at=excluded.client_updated_at,deleted_at=excluded.deleted_at,
                  payload_json=excluded.payload_json
                """,
            arguments: [
                photo.id,photo.capturedAt,photo.pose.rawValue,photo.bodyWeightKg,
                try photo.measurementSnapshotJson.map(json),photo.phaseId,photo.phaseName,
                photo.originalAssetId,photo.thumbnailAssetId,photo.originalState ?? "ready",
                photo.thumbnailState,photo.notes,photo.metadataAcknowledged == true,
                photo.revision ?? 0,now,photo.deletedAt,try json(photo),
            ]
        )
    }

    private func cleanupAcknowledgedOriginal(assetId: String) throws {
        let state: (String,Bool,Bool)? = try database.read { db in
            guard let row = try Row.fetchOne(db,sql: "SELECT * FROM fitness_private_file_uploads WHERE asset_id=?",arguments: [assetId]) else { return nil }
            return (row["relative_path"],(row["upload_acknowledged"] as Int) != 0,(row["metadata_acknowledged"] as Int) != 0)
        }
        guard let state,state.1,state.2 else { return }
        let url = try absoluteURL(relativePath: state.0)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try database.write { db in
            try db.execute(sql: "DELETE FROM fitness_private_file_uploads WHERE asset_id=? AND upload_acknowledged=1 AND metadata_acknowledged=1",arguments: [assetId])
        }
    }

    private static func isOwnedProgressPhotoFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".jpg") else { return false }
        let uuid = String(filename.dropLast(4))
        return uuid.count == 36
            && uuid == uuid.lowercased()
            && UUID(uuidString: uuid) != nil
    }

    private static func isOwnedProgressPhotoArtifactFilename(_ filename: String) -> Bool {
        if isOwnedProgressPhotoFilename(filename) { return true }
        guard filename.hasPrefix("."),filename.hasSuffix(".staging") else { return false }
        let uuid = String(filename.dropFirst().dropLast(".staging".count))
        return uuid.count == 36
            && uuid == uuid.lowercased()
            && UUID(uuidString: uuid) != nil
    }

    private func photoCacheDirectory() throws -> URL {
        guard let root = database.activeStoreURL?.deletingLastPathComponent() else { throw FitnessDatabaseError.notActive }
        let directory = root.appendingPathComponent("PrivateCache/ProgressPhotos",isDirectory: true)
        try LocalFileProtection.prepareDirectory(directory,fileManager: fileManager)
        return directory
    }

    private func absoluteURL(relativePath: String) throws -> URL {
        guard let root = database.activeStoreURL?.deletingLastPathComponent().standardizedFileURL else { throw FitnessDatabaseError.notActive }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw FitnessHealthRepositoryError.unsafePath }
        return url
    }

    private func removeCachedRepresentations(photoId: String) throws {
        let urls: [URL] = try database.read { db in
            try String.fetchAll(
                db,
                sql:"SELECT relative_path FROM fitness_progress_photo_cache WHERE photo_id=?",
                arguments:[photoId]
            ).map { try absoluteURL(relativePath:$0) }
        }
        for url in urls where fileManager.fileExists(atPath:url.path) {
            try fileManager.removeItem(at:url)
        }
        try database.write { db in
            try db.execute(
                sql:"DELETE FROM fitness_progress_photo_cache WHERE photo_id=?",
                arguments:[photoId]
            )
        }
    }

    private func removeProgressPhotoArtifactIfPresent(_ url:URL,context:String) {
        guard fileManager.fileExists(atPath:url.path) else { return }
        do {
            let values = try url.resourceValues(forKeys:[
                .isRegularFileKey,.isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,values.isSymbolicLink != true else {
                fitnessHealthRepositoryLogger.error(
                    "Refused non-regular cleanup target after \(context, privacy: .public)."
                )
                return
            }
            try fileManager.removeItem(at:url)
        } catch {
            fitnessHealthRepositoryLogger.error(
                "Cleanup failed after \(context, privacy: .public); launch reconciliation will retry where applicable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func isJPEG(_ data:Data) -> Bool {
        data.count>=4 && data[data.startIndex]==0xFF && data[data.startIndex+1]==0xD8
            && data[data.endIndex-2]==0xFF && data[data.endIndex-1]==0xD9
    }

    private static func isJPEGFile(_ url:URL) throws -> Bool {
        let handle=try FileHandle(forReadingFrom:url)
        do {
            let start=try handle.read(upToCount:2) ?? Data()
            let length=try handle.seekToEnd()
            let valid: Bool
            if start == Data([0xFF,0xD8]),length >= 4 {
                try handle.seek(toOffset:length-2)
                valid = try handle.read(upToCount:2) == Data([0xFF,0xD9])
            } else {
                valid = false
            }
            try handle.close()
            return valid
        } catch {
            closeFileHandleAfterFallback(handle,context:"JPEG validation")
            throw error
        }
    }

    private static func closeFileHandleAfterFallback(
        _ handle:FileHandle,context:String
    ) {
        do {
            try handle.close()
        } catch {
            fitnessHealthRepositoryLogger.error(
                "File-handle cleanup failed after \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value),as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type,_ string: String) throws -> T {
        try decoder.decode(type,from: Data(string.utf8))
    }

    private func decodeJSON<T: Decodable>(_ string: String?) throws -> T? {
        guard let string else { return nil }
        return try decoder.decode(T.self,from: Data(string.utf8))
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),!value.isEmpty else { return nil }
        return value
    }
}
