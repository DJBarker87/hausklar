import Foundation
import GRDB
import os

private let fitnessActivityRepositoryLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "FitnessActivityRepository"
)

enum FitnessActivityRepositoryError: LocalizedError {
    case invalidFIT
    case missingLocalFIT
    case unsafeSharedFile

    var errorDescription: String? {
        switch self {
        case .invalidFIT: "Choose a non-empty FIT file no larger than 64 MB."
        case .missingLocalFIT: "The pending FIT copy is no longer available on this device."
        case .unsafeSharedFile: "HausKlar refused a shared file outside its protected inbox."
        }
    }
}

struct FitnessPendingContextMutation: Sendable {
    let mutationId: String
    let activityId: String
    let update: FitnessActivityContextUpdate
}

actor FitnessActivityRepository {
    static let shared = FitnessActivityRepository()

    private let database: FitnessDatabase
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(database: FitnessDatabase = .shared, fileManager: FileManager = .default) {
        self.database = database
        self.fileManager = fileManager
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
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = FitnessDatabase.date(value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid Fitness timestamp"
                )
            }
            return date
        }
        self.decoder = decoder
    }

    // MARK: FIT inbox

    func stageFIT(
        at sourceURL: URL,
        id: String = UUID().uuidString,
        originalFilename: String? = nil,
        mediaType: String = "application/vnd.ant.fit"
    ) throws -> FitnessPendingFITImport {
        guard UUID(uuidString: id) != nil,
              sourceURL.pathExtension.lowercased() == "fit" else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        let sourceValues = try sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard
              sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        let byteCount = sourceValues.fileSize ?? 0
        guard byteCount > 0, byteCount <= 64 * 1_024 * 1_024 else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        let directory = try pendingFITDirectory()
        let localFilename = "\(id.lowercased()).fit"
        let destination = directory.appendingPathComponent(localFilename)
        if !fileManager.fileExists(atPath: destination.path) {
            let staging = directory.appendingPathComponent(".\(id.lowercased()).staging")
            if fileManager.fileExists(atPath: staging.path) {
                let values = try staging.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw FitnessActivityRepositoryError.invalidFIT
                }
                try fileManager.removeItem(at: staging)
            } else if try symbolicLinkExists(at: staging) {
                throw FitnessActivityRepositoryError.invalidFIT
            }
            do {
                try fileManager.copyItem(at: sourceURL, to: staging)
                let stagedValues = try staging.resourceValues(forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard stagedValues.isRegularFile == true,
                      stagedValues.isSymbolicLink != true,
                      stagedValues.fileSize == byteCount else {
                    throw FitnessActivityRepositoryError.invalidFIT
                }
                try LocalFileProtection.protectItem(at: staging, fileManager: fileManager)
                try fileManager.moveItem(at: staging, to: destination)
                try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
            } catch {
                removeGarminSourceIfRegular(
                    staging,context:"failed pending-FIT publication"
                )
                throw error
            }
        }
        let destinationValues = try destination.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard destinationValues.isRegularFile == true,
              destinationValues.isSymbolicLink != true,
              destinationValues.fileSize == byteCount else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_fit_imports
                    (id,original_filename,local_filename,media_type,byte_count,status,retryable,
                     created_at,updated_at)
                    VALUES (?,?,?,?,?,'queued',1,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      local_filename=COALESCE(fitness_fit_imports.local_filename, excluded.local_filename),
                      updated_at=excluded.updated_at
                    """,
                arguments: [
                    id,Self.safeFilename(originalFilename ?? sourceURL.lastPathComponent),localFilename,
                    mediaType,byteCount,now,now,
                ]
            )
        }
        return try pendingFITImport(id: id)
    }

    func pendingFITImports() throws -> [FitnessPendingFITImport] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM fitness_fit_imports ORDER BY created_at DESC"
            ).map(Self.pendingFIT)
        }
    }

    func uploadableFITImports() throws -> [FitnessPendingFITImport] {
        try pendingFITImports().filter {
            !$0.sourceRetained && $0.hasLocalCopy
                && ($0.serverImportId == nil || $0.status == .queued)
        }
    }

    func pollableFITImports() throws -> [FitnessPendingFITImport] {
        try pendingFITImports().filter {
            !$0.sourceRetained && $0.serverImportId != nil
                && $0.status != .error
        }
    }

    /// Reclaims only stale, unreferenced files in the currently active owner's
    /// PendingFIT directory. The database reference set is captured before any
    /// deletion; malformed names, symlinks, directories, and fresh writes stay.
    @discardableResult
    func reconcilePendingFITFiles(
        now: Date = Date(),
        minimumAge: TimeInterval = 24 * 60 * 60,
        maximumCandidates: Int = 256,
        maximumRemovals: Int = 32
    ) throws -> Int {
        guard maximumCandidates > 0, maximumRemovals > 0 else { return 0 }
        let directory = try pendingFITDirectory().standardizedFileURL
        let referenced = try database.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT local_filename FROM fitness_fit_imports WHERE local_filename IS NOT NULL"
            ))
        }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        guard let entries = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) else { return 0 }
        let cutoff = now.addingTimeInterval(-max(0, minimumAge))
        var removed = 0
        var inspected = 0
        while inspected < maximumCandidates,
              removed < maximumRemovals,
              let entry = entries.nextObject() as? URL {
            inspected += 1
            let candidate = entry.standardizedFileURL
            let filename = candidate.lastPathComponent
            guard candidate.deletingLastPathComponent() == directory,
                  !referenced.contains(filename),
                  Self.isOwnedPendingFITFilename(filename) else { continue }
            let values = try candidate.resourceValues(forKeys: keys)
            guard
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate ?? values.creationDate,
                  modified <= cutoff else { continue }
            do {
                try fileManager.removeItem(at: candidate)
                removed += 1
            } catch {
                fitnessActivityRepositoryLogger.error(
                    "Pending-FIT reconciliation could not remove an owned orphan; a later reconciliation will retry: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
        }
        return removed
    }

    func localFITURL(for id: String) throws -> URL {
        guard let filename: String = try database.read({ db in
            try String.fetchOne(
                db, sql: "SELECT local_filename FROM fitness_fit_imports WHERE id = ?", arguments: [id]
            )
        }) else { throw FitnessActivityRepositoryError.missingLocalFIT }
        let directory = try pendingFITDirectory().standardizedFileURL
        let url = directory.appendingPathComponent(filename).standardizedFileURL
        guard Self.isOwnedFinalFITFilename(filename),
              url.deletingLastPathComponent() == directory else {
            throw FitnessActivityRepositoryError.missingLocalFIT
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= 64 * 1_024 * 1_024 else {
            throw FitnessActivityRepositoryError.missingLocalFIT
        }
        return url
    }

    func markFITUploading(_ id: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_fit_imports
                    SET status='uploading',attempt_count=attempt_count+1,last_error=NULL,updated_at=?
                    WHERE id=? AND source_retained=0
                    """,
                arguments: [FitnessDatabase.dateString(Date()),id]
            )
        }
    }

    func markFITQueued(_ id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE fitness_fit_imports SET status='queued',last_error=NULL,updated_at=? WHERE id=?",
                arguments: [FitnessDatabase.dateString(Date()),id]
            )
        }
    }

    func markFITFailure(_ id: String, message: String, retryable: Bool = true) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_fit_imports
                    SET status='error',last_error=?,retryable=?,updated_at=? WHERE id=?
                    """,
                arguments: [String(message.prefix(1_000)),retryable,FitnessDatabase.dateString(Date()),id]
            )
        }
    }

    func markFITTransientFailure(_ id: String, message: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_fit_imports
                    SET status='queued',last_error=?,retryable=1,updated_at=? WHERE id=?
                    """,
                arguments: [String(message.prefix(1_000)),FitnessDatabase.dateString(Date()),id]
            )
        }
    }

    func applyFITResult(localId: String, result: FitnessFITImportResult) throws {
        let acknowledged = result.sourceRetained == true && result.sourceRecordId != nil
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_fit_imports SET
                      status=?,server_import_id=?,activity_id=?,source_record_id=?,source_retained=?,
                      retryable=?,last_error=?,updated_at=? WHERE id=?
                    """,
                arguments: [
                    result.status.rawValue,result.id,result.activityId,result.sourceRecordId,acknowledged,
                    result.retryable ?? true,result.error,result.updatedAt ?? FitnessDatabase.dateString(Date()),localId,
                ]
            )
        }
        guard acknowledged else { return }
        let filename: String? = try database.read { db in
            try String.fetchOne(
                db, sql: "SELECT local_filename FROM fitness_fit_imports WHERE id = ?", arguments: [localId]
            )
        }
        if let filename {
            let url = try pendingFITDirectory().appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        try database.write { db in
            try db.execute(
                sql: "UPDATE fitness_fit_imports SET local_filename=NULL WHERE id=? AND source_retained=1",
                arguments: [localId]
            )
        }
    }

    func removeAcknowledgedFITImport(_ id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM fitness_fit_imports WHERE id=? AND source_retained=1",
                arguments: [id]
            )
        }
    }

    // MARK: Activity cache and context outbox

    func cacheActivityRegistry(_ value: FitnessActivityRegistry) throws {
        try cachePayload(
            value,table: "fitness_analysis_registry_cache",
            keyColumn: "cache_key",key: "activity_registry"
        )
    }

    func cachedActivityRegistry() throws -> FitnessActivityRegistry? {
        try cachedPayload(
            FitnessActivityRegistry.self,table: "fitness_analysis_registry_cache",
            keyColumn: "cache_key",key: "activity_registry"
        )
    }

    func cacheActivities(_ activities: [FitnessActivitySummary]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            for activity in activities {
                let payload = try json(activity)
                let gearIds = try json((activity.gear ?? []).map(\.id))
                try db.execute(
                    sql: """
                        INSERT INTO fitness_activities
                        (id,title,sport_key,started_at_utc,status,workout_classification,phase_id,
                         gear_ids_json,distance_m,duration_s,revision,server_updated_at,payload_json,cached_at)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET
                          title=excluded.title,sport_key=excluded.sport_key,
                          started_at_utc=excluded.started_at_utc,status=excluded.status,
                          workout_classification=excluded.workout_classification,phase_id=excluded.phase_id,
                          gear_ids_json=excluded.gear_ids_json,distance_m=excluded.distance_m,
                          duration_s=excluded.duration_s,revision=excluded.revision,
                          server_updated_at=excluded.server_updated_at,payload_json=excluded.payload_json,
                          cached_at=excluded.cached_at,deleted_at=NULL
                        """,
                    arguments: [
                        activity.id,activity.title,activity.sportKey,activity.startedAtUtc,activity.status,
                        activity.workoutClassification,activity.phaseId,gearIds,activity.distanceM,
                        activity.durationS ?? activity.timerDurationS,activity.revision ?? 0,
                        activity.updatedAt,payload,now,
                    ]
                )
            }
        }
    }

    func cachedActivities(
        filter: FitnessActivityFilter = .init(),
        offset: Int = 0,
        limit: Int = 100
    ) throws -> [FitnessActivitySummary] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT payload_json FROM fitness_activities
                    WHERE deleted_at IS NULL
                      AND (? IS NULL OR sport_key = ?)
                      AND (? IS NULL OR substr(started_at_utc,1,10) >= ?)
                      AND (? IS NULL OR substr(started_at_utc,1,10) <= ?)
                      AND (? IS NULL OR phase_id = ?)
                      AND (? IS NULL OR workout_classification = ?)
                      AND (? IS NULL OR EXISTS (
                        SELECT 1 FROM json_each(fitness_activities.gear_ids_json) WHERE value = ?
                      ))
                      AND (? IS NULL OR status = ?)
                    ORDER BY started_at_utc DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [
                    filter.sportKey,filter.sportKey,filter.dateFrom,filter.dateFrom,
                    filter.dateTo,filter.dateTo,filter.phaseId,filter.phaseId,
                    filter.workoutClassification,filter.workoutClassification,
                    filter.gearId,filter.gearId,filter.status,filter.status,
                    min(200,max(1,limit)),max(0,offset),
                ]
            ).map { try decode(FitnessActivitySummary.self, from: $0) }
        }
    }

    func cachedManualActivityDefaults() throws -> FitnessManualActivityDefaults {
        try database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(value_number,weight_kg) AS weight_kg,measured_at
                    FROM fitness_body_measurements
                    WHERE deleted_at IS NULL AND is_canonical=1
                      AND COALESCE(metric_key,'body.weight_kg')='body.weight_kg'
                    ORDER BY measured_at DESC LIMIT 1
                    """
            )
            return FitnessManualActivityDefaults(
                latestWeightKg: row?["weight_kg"],
                latestWeightMeasuredAtUtc: row?["measured_at"],
                energyEstimationMethod: "adult_compendium_2024_met"
            )
        }
    }

    func queueManualActivity(
        payload: FitnessManualActivityPayload,
        optimistic activity: FitnessActivitySummary
    ) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_activities
                    (id,title,sport_key,started_at_utc,status,workout_classification,phase_id,
                     gear_ids_json,distance_m,duration_s,revision,server_updated_at,payload_json,cached_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,0,NULL,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      title=excluded.title,sport_key=excluded.sport_key,
                      started_at_utc=excluded.started_at_utc,status=excluded.status,
                      workout_classification=excluded.workout_classification,
                      distance_m=excluded.distance_m,duration_s=excluded.duration_s,
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at,deleted_at=NULL
                    """,
                arguments: [
                    activity.id,activity.title,activity.sportKey,activity.startedAtUtc,
                    activity.status,activity.workoutClassification,activity.phaseId,"[]",
                    activity.distanceM,activity.durationS,try json(activity),now,
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_outbox
                    (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                     base_revision,payload_json,created_at_client)
                    VALUES (?,? ,?,'upsert',?,NULL,?,?)
                    """,
                arguments: [
                    UUID().uuidString,FitnessEntityType.manualActivity.rawValue,payload.id,
                    FitnessContract.payloadSchemaVersion,try json(payload),now,
                ]
            )
        }
    }

    func cacheDetail(_ detail: FitnessActivityDetail) throws {
        try cacheActivities([detail.activity])
        if let gear = detail.gear { try cacheGear(gear) }
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_activity_details(activity_id,payload_json,cached_at) VALUES (?,?,?)
                    ON CONFLICT(activity_id) DO UPDATE SET
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at
                    """,
                arguments: [detail.activity.id,try json(detail),FitnessDatabase.dateString(Date())]
            )
        }
    }

    func cachedDetail(_ activityId: String) throws -> FitnessActivityDetail? {
        try database.read { db in
            guard let value = try String.fetchOne(
                db, sql: "SELECT payload_json FROM fitness_activity_details WHERE activity_id=?", arguments: [activityId]
            ) else { return nil }
            return try decode(FitnessActivityDetail.self, from: value)
        }
    }

    func cacheStream(
        _ stream: FitnessActivityStream,
        metrics: [String],
        fromOffsetMs: Int?,
        toOffsetMs: Int?,
        maxPoints: Int
    ) throws {
        let key = Self.streamCacheKey(
            activityId: stream.activityId, clock: stream.clock, metrics: metrics,
            fromOffsetMs: fromOffsetMs, toOffsetMs: toOffsetMs, maxPoints: maxPoints
        )
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_activity_stream_ranges
                    (cache_key,activity_id,clock,metrics_key,from_offset_ms,to_offset_ms,max_points,payload_json,cached_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(cache_key) DO UPDATE SET
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at
                    """,
                arguments: [
                    key,stream.activityId,stream.clock,metrics.sorted().joined(separator: ","),
                    fromOffsetMs,toOffsetMs,maxPoints,try json(stream),FitnessDatabase.dateString(Date()),
                ]
            )
        }
    }

    func cachedStream(
        activityId: String,
        clock: String,
        metrics: [String],
        fromOffsetMs: Int?,
        toOffsetMs: Int?,
        maxPoints: Int
    ) throws -> FitnessActivityStream? {
        let key = Self.streamCacheKey(
            activityId: activityId, clock: clock, metrics: metrics,
            fromOffsetMs: fromOffsetMs, toOffsetMs: toOffsetMs, maxPoints: maxPoints
        )
        return try database.read { db in
            guard let value = try String.fetchOne(
                db, sql: "SELECT payload_json FROM fitness_activity_stream_ranges WHERE cache_key=?", arguments: [key]
            ) else { return nil }
            return try decode(FitnessActivityStream.self, from: value)
        }
    }

    func queueContextUpdate(activityId: String, update: FitnessActivityContextUpdate) throws {
        let mutationId = UUID().uuidString
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            // A complete context form supersedes an older unsent edit for this activity.
            try db.execute(
                sql: "DELETE FROM fitness_activity_context_outbox WHERE activity_id=?",
                arguments: [activityId]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_activity_context_outbox
                    (mutation_id,activity_id,payload_json,created_at) VALUES (?,?,?,?)
                    """,
                arguments: [mutationId,activityId,try json(update),now]
            )
        }
        try applyOptimisticContext(activityId: activityId, update: update)
    }

    func pendingContextMutations() throws -> [FitnessPendingContextMutation] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM fitness_activity_context_outbox ORDER BY created_at,mutation_id"
            ).map { row in
                FitnessPendingContextMutation(
                    mutationId: row["mutation_id"],activityId: row["activity_id"],
                    update: try decode(FitnessActivityContextUpdate.self, from: row["payload_json"])
                )
            }
        }
    }

    func acknowledgeContextMutation(_ mutationId: String, detail: FitnessActivityDetail) throws {
        try cacheDetail(detail)
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM fitness_activity_context_outbox WHERE mutation_id=?",
                arguments: [mutationId]
            )
        }
    }

    func markContextFailure(_ mutationId: String, message: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE fitness_activity_context_outbox SET attempt_count=attempt_count+1,
                      last_attempt_at=?,last_error=? WHERE mutation_id=?
                    """,
                arguments: [FitnessDatabase.dateString(Date()),String(message.prefix(1_000)),mutationId]
            )
        }
    }

    // MARK: Typed secondary caches

    func cacheGear(_ gear: [FitnessGearItem]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            for item in gear {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_gear_items
                        (id,gear_type_key,name,active,default_for_sport_key,revision,payload_json,cached_at,deleted_at)
                        VALUES (?,?,?,?,?,?,?,?,NULL)
                        ON CONFLICT(id) DO UPDATE SET
                          gear_type_key=excluded.gear_type_key,name=excluded.name,active=excluded.active,
                          default_for_sport_key=excluded.default_for_sport_key,revision=excluded.revision,
                          payload_json=excluded.payload_json,cached_at=excluded.cached_at,deleted_at=NULL
                        """,
                    arguments: [
                        item.id,item.gearTypeKey,item.name,item.active ?? true,item.defaultForSportKey,
                        item.revision ?? 0,try json(item),now,
                    ]
                )
            }
        }
    }

    func cachedGear() throws -> [FitnessGearItem] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT payload_json FROM fitness_gear_items WHERE deleted_at IS NULL ORDER BY active DESC,name"
            ).map { try decode(FitnessGearItem.self, from: $0) }
        }
    }

    func cacheAnalysis(_ response: FitnessActivityAnalysisResponse, activityId: String) throws {
        try cachePayload(response, table: "fitness_activity_analysis_cache", keyColumn: "activity_id", key: activityId)
    }

    func cachedAnalysis(_ activityId: String) throws -> FitnessActivityAnalysisResponse? {
        try cachedPayload(FitnessActivityAnalysisResponse.self, table: "fitness_activity_analysis_cache", keyColumn: "activity_id", key: activityId)
    }

    func cacheComparisons(_ values: [FitnessComparableRun], activityId: String) throws {
        try cachePayload(values, table: "fitness_activity_comparisons_cache", keyColumn: "activity_id", key: activityId)
    }

    func cachedComparisons(_ activityId: String) throws -> [FitnessComparableRun]? {
        try cachedPayload([FitnessComparableRun].self, table: "fitness_activity_comparisons_cache", keyColumn: "activity_id", key: activityId)
    }

    func cacheAdherence(_ value: FitnessPlanAdherence, ownerType: String, ownerId: String) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_activity_adherence_cache
                    (owner_type,owner_id,payload_json,cached_at) VALUES (?,?,?,?)
                    ON CONFLICT(owner_type,owner_id) DO UPDATE SET
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at
                    """,
                arguments: [ownerType,ownerId,try json(value),FitnessDatabase.dateString(Date())]
            )
        }
    }

    func cachedAdherence(ownerType: String, ownerId: String) throws -> FitnessPlanAdherence? {
        try database.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT payload_json FROM fitness_activity_adherence_cache WHERE owner_type=? AND owner_id=?",
                arguments: [ownerType,ownerId]
            ) else { return nil }
            return try decode(FitnessPlanAdherence.self, from: value)
        }
    }

    func replaceCalendarLayer(_ items: [FitnessCalendarLayerItem]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(sql: "DELETE FROM fitness_calendar_layer_items")
            for item in items {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_calendar_layer_items
                        (id,layer_kind,scheduled_start_utc,scheduled_date,payload_json,cached_at)
                        VALUES (?,?,?,?,?,?)
                        """,
                    arguments: [
                        item.id,item.layerKind,item.scheduledStartUtc,item.scheduledDate,try json(item),now,
                    ]
                )
            }
        }
    }

    func cachedCalendarLayer() throws -> [FitnessCalendarLayerItem] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT payload_json FROM fitness_calendar_layer_items ORDER BY COALESCE(scheduled_start_utc,scheduled_date)"
            ).map { try decode(FitnessCalendarLayerItem.self, from: $0) }
        }
    }

    func cacheAnalysisRegistry(_ value: FitnessAnalysisRegistry) throws {
        try cachePayload(value, table: "fitness_analysis_registry_cache", keyColumn: "cache_key", key: "registry")
    }

    func cachedAnalysisRegistry() throws -> FitnessAnalysisRegistry? {
        try cachedPayload(FitnessAnalysisRegistry.self, table: "fitness_analysis_registry_cache", keyColumn: "cache_key", key: "registry")
    }

    func cacheAnalysisQuery(_ value: FitnessAnalysisQueryResult, request: FitnessAnalysisQueryRequest) throws {
        try cachePayload(
            value,table: "fitness_analysis_query_cache",keyColumn: "cache_key",
            key: Self.analysisQueryKey(request)
        )
    }

    func cachedAnalysisQuery(_ request: FitnessAnalysisQueryRequest) throws -> FitnessAnalysisQueryResult? {
        try cachedPayload(
            FitnessAnalysisQueryResult.self,table: "fitness_analysis_query_cache",keyColumn: "cache_key",
            key: Self.analysisQueryKey(request)
        )
    }

    func replaceSavedAnalysisCharts(_ values: [FitnessSavedAnalysisChart]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(sql: "DELETE FROM fitness_saved_analysis_charts_cache")
            for value in values where value.deletedAt == nil {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_saved_analysis_charts_cache(id,payload_json,cached_at)
                        VALUES (?,?,?)
                        """,
                    arguments: [value.id,try json(value),now]
                )
            }
        }
    }

    func cacheSavedAnalysisChart(_ value: FitnessSavedAnalysisChart) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_saved_analysis_charts_cache(id,payload_json,cached_at)
                    VALUES (?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at
                    """,
                arguments: [value.id,try json(value),FitnessDatabase.dateString(Date())]
            )
        }
    }

    func removeCachedSavedAnalysisChart(_ id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM fitness_saved_analysis_charts_cache WHERE id=?",
                arguments: [id]
            )
        }
    }

    func cachedSavedAnalysisCharts() throws -> [FitnessSavedAnalysisChart] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT payload_json FROM fitness_saved_analysis_charts_cache ORDER BY cached_at DESC,id"
            ).map { try decode(FitnessSavedAnalysisChart.self, from: $0) }
        }
    }

    // MARK: Run plans and Garmin

    func saveRunPlanDraft(_ draft: FitnessRunPlanDraft) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_run_plan_drafts(id,definition_id,payload_json,created_at,updated_at)
                    VALUES (?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      definition_id=excluded.definition_id,payload_json=excluded.payload_json,
                      updated_at=excluded.updated_at
                    """,
                arguments: [draft.id,draft.definitionId,try json(draft),now,now]
            )
        }
    }

    func runPlanDrafts() throws -> [FitnessRunPlanDraft] {
        try database.read { db in
            try String.fetchAll(
                db, sql: "SELECT payload_json FROM fitness_run_plan_drafts ORDER BY updated_at DESC"
            ).map { try decode(FitnessRunPlanDraft.self, from: $0) }
        }
    }

    func deleteRunPlanDraft(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM fitness_run_plan_drafts WHERE id=?", arguments: [id])
        }
    }

    func cacheWorkoutDefinitions(_ definitions: [FitnessWorkoutDefinitionDTO]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            for definition in definitions {
                let versions = definition.versions
                    ?? definition.currentVersion.map { [$0] }
                    ?? definition.version.map { [$0] }
                    ?? []
                let currentId = definition.currentVersion?.id ?? definition.version?.id ?? versions.first?.id
                try db.execute(
                    sql: """
                        INSERT INTO fitness_workout_definitions
                        (id,sport_key,name,description,active,current_version_id,revision,
                         client_updated_at,origin_device_id,payload_json)
                        VALUES (?,?,?,?,?,?,?,?,'server',?)
                        ON CONFLICT(id) DO UPDATE SET
                          sport_key=excluded.sport_key,name=excluded.name,description=excluded.description,
                          active=excluded.active,current_version_id=excluded.current_version_id,
                          revision=excluded.revision,client_updated_at=excluded.client_updated_at,
                          payload_json=excluded.payload_json,deleted_at=NULL
                        """,
                    arguments: [
                        definition.id,definition.sportKey,definition.name,definition.description,
                        definition.active,currentId,definition.revision ?? 0,
                        definition.updatedAt ?? now,try json(definition),
                    ]
                )
                for version in versions {
                    try cacheWorkoutVersion(version, definitionId: definition.id, db: db, now: now)
                }
            }
        }
    }

    func cachedWorkoutDefinitions(sportKey: String = "running") throws -> [FitnessWorkoutDefinitionDTO] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT payload_json FROM fitness_workout_definitions
                    WHERE sport_key=? AND active=1 AND deleted_at IS NULL AND payload_json IS NOT NULL
                    ORDER BY name
                    """,
                arguments: [sportKey]
            ).map { try decode(FitnessWorkoutDefinitionDTO.self, from: $0) }
        }
    }

    func cacheTrainingProgrammes(_ programmes: [FitnessTrainingProgrammeDTO]) throws {
        let now = FitnessDatabase.dateString(Date())
        try database.write { db in
            for programme in programmes {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_training_programmes
                        (id,name,purpose,starts_on,ends_on,status,phase_id,programme_source,revision,
                         client_updated_at,origin_device_id,payload_json)
                        VALUES (?,?,?,?,?,?,?,?,?,?,'server',?)
                        ON CONFLICT(id) DO UPDATE SET
                          name=excluded.name,purpose=excluded.purpose,starts_on=excluded.starts_on,
                          ends_on=excluded.ends_on,status=excluded.status,phase_id=excluded.phase_id,
                          programme_source=excluded.programme_source,revision=excluded.revision,
                          client_updated_at=excluded.client_updated_at,payload_json=excluded.payload_json,
                          deleted_at=NULL
                        """,
                    arguments: [
                        programme.id,programme.name,programme.purpose,programme.startsOn,programme.endsOn,
                        programme.status,programme.phaseId,programme.programmeSource,programme.revision ?? 0,
                        programme.updatedAt ?? now,try json(programme),
                    ]
                )
            }
        }
    }

    func cachedTrainingProgrammes() throws -> [FitnessTrainingProgrammeDTO] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT payload_json FROM fitness_training_programmes
                    WHERE deleted_at IS NULL AND payload_json IS NOT NULL ORDER BY starts_on DESC
                    """
            ).map { try decode(FitnessTrainingProgrammeDTO.self, from: $0) }
        }
    }

    func cacheGarminExport(_ value: FitnessGarminExport, localFilename: String? = nil) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_garmin_exports
                    (id,workout_version_id,status,file_name,local_filename,payload_json,cached_at)
                    VALUES (?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET
                      status=excluded.status,file_name=excluded.file_name,
                      local_filename=COALESCE(excluded.local_filename,fitness_garmin_exports.local_filename),
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at
                    """,
                arguments: [
                    value.id,value.workoutVersionId,value.status,value.fileName,localFilename,
                    try json(value),FitnessDatabase.dateString(Date()),
                ]
            )
        }
    }

    func cachedGarminExports(workoutVersionId: String? = nil) throws -> [FitnessGarminExport] {
        try database.read { db in
            let rows: [String]
            if let workoutVersionId {
                rows = try String.fetchAll(
                    db,
                    sql: "SELECT payload_json FROM fitness_garmin_exports WHERE workout_version_id=? ORDER BY cached_at DESC",
                    arguments: [workoutVersionId]
                )
            } else {
                rows = try String.fetchAll(db, sql: "SELECT payload_json FROM fitness_garmin_exports ORDER BY cached_at DESC")
            }
            return try rows.map { try decode(FitnessGarminExport.self, from: $0) }
        }
    }

    /// Adopts the already file-backed API download without ever materialising
    /// the FIT payload as `Data`. The generated file is structurally checked
    /// before publication and is removed again if metadata persistence fails.
    func adoptGarminDownload(at source: URL, export: FitnessGarminExport) throws -> URL {
        // `adopt` transfers ownership immediately: even a malformed or
        // unpublishable temporary file must not survive for the next launch.
        var sourceConsumed = false
        defer {
            if !sourceConsumed { removeGarminSourceIfRegular(source) }
        }
        guard UUID(uuidString: export.id) != nil,
              source.pathExtension.lowercased() == "fit" else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        let sourceValues = try source.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard
              sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let byteCount = sourceValues.fileSize,
              byteCount > 0,
              byteCount <= 8 * 1_024 * 1_024,
              try Self.hasValidFITEnvelope(at: source, byteCount: byteCount) else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        guard let root = database.activeStoreURL?.deletingLastPathComponent() else {
            throw FitnessDatabaseError.notActive
        }
        let directory = root.appendingPathComponent("GarminExports", isDirectory: true)
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        let filename = "\(export.id.lowercased()).fit"
        let destination = directory.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            let existingValues = try destination.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard existingValues.isRegularFile == true,
                  existingValues.isSymbolicLink != true,
                  let existingBytes = existingValues.fileSize,
                  existingBytes > 0,
                  existingBytes <= 8 * 1_024 * 1_024,
                  try Self.hasValidFITEnvelope(at: destination, byteCount: existingBytes) else {
                throw FitnessActivityRepositoryError.invalidFIT
            }
            try cacheGarminExport(export, localFilename: filename)
            removeGarminSourceIfRegular(
                source,context:"duplicate Garmin download adoption"
            )
            sourceConsumed = true
            return destination
        }

        let staging = directory.appendingPathComponent(".\(export.id.lowercased()).staging")
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        var published = false
        defer {
            if !published {
                removeGarminSourceIfRegular(
                    staging,context:"failed Garmin staging publication"
                )
                removeGarminSourceIfRegular(
                    destination,context:"failed Garmin final publication"
                )
            }
        }
        try fileManager.moveItem(at: source, to: staging)
        sourceConsumed = true
        try LocalFileProtection.protectItem(at: staging, fileManager: fileManager)
        try fileManager.moveItem(at: staging, to: destination)
        try LocalFileProtection.protectItem(at: destination, fileManager: fileManager)
        let publishedValues = try destination.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard publishedValues.isRegularFile == true,
              publishedValues.isSymbolicLink != true,
              publishedValues.fileSize == byteCount,
              try Self.hasValidFITEnvelope(at: destination, byteCount: byteCount) else {
            throw FitnessActivityRepositoryError.invalidFIT
        }
        try cacheGarminExport(export, localFilename: filename)
        published = true
        return destination
    }

    func garminDownloadURL(exportId: String) throws -> URL? {
        guard UUID(uuidString: exportId) != nil else { return nil }
        guard let filename: String = try database.read({ db in
            try String.fetchOne(
                db, sql: "SELECT local_filename FROM fitness_garmin_exports WHERE id=?", arguments: [exportId]
            )
        }), let root = database.activeStoreURL?.deletingLastPathComponent() else { return nil }
        let expectedFilename = "\(exportId.lowercased()).fit"
        guard filename == expectedFilename else { return nil }
        let directory = root.appendingPathComponent("GarminExports", isDirectory: true)
            .standardizedFileURL
        let url = directory.appendingPathComponent(filename).standardizedFileURL
        guard url.deletingLastPathComponent() == directory else { return nil }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let byteCount = values.fileSize,
              byteCount > 0,
              byteCount <= 8 * 1_024 * 1_024,
              try Self.hasValidFITEnvelope(at: url, byteCount: byteCount) else { return nil }
        return url
    }

    // MARK: Helpers

    private func removeGarminSourceIfRegular(
        _ url: URL,context: String = "temporary Garmin source"
    ) {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,values.isSymbolicLink != true else {
                fitnessActivityRepositoryLogger.error(
                    "Refused non-regular cleanup target after \(context, privacy: .public)."
                )
                return
            }
            try fileManager.removeItem(at:url)
        } catch let error as CocoaError where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        } catch {
            fitnessActivityRepositoryLogger.error(
                "Cleanup failed after \(context, privacy: .public); reconciliation will retry where applicable: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func symbolicLinkExists(at url: URL) throws -> Bool {
        do {
            _ = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            return true
        } catch let error as CocoaError where
            error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        }
    }

    private static func hasValidFITEnvelope(at url: URL, byteCount: Int) throws -> Bool {
        guard byteCount >= 14 else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        let prefix: Data
        do {
            prefix = try handle.read(upToCount: 14) ?? Data()
            try handle.close()
        } catch {
            do {
                try handle.close()
            } catch {
                fitnessActivityRepositoryLogger.error(
                    "FIT validation handle cleanup failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
        guard prefix.count >= 12 else { return false }
        let headerSize = Int(prefix[0])
        guard headerSize == 12 || headerSize == 14,
              prefix[8] == 0x2E,
              prefix[9] == 0x46,
              prefix[10] == 0x49,
              prefix[11] == 0x54 else { return false }
        let dataSize = UInt64(prefix[4])
            | (UInt64(prefix[5]) << 8)
            | (UInt64(prefix[6]) << 16)
            | (UInt64(prefix[7]) << 24)
        return dataSize <= UInt64(Int.max - headerSize - 2)
            && byteCount == headerSize + Int(dataSize) + 2
    }

    private func pendingFITImport(id: String) throws -> FitnessPendingFITImport {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM fitness_fit_imports WHERE id=?", arguments: [id]
            ) else { throw FitnessActivityRepositoryError.missingLocalFIT }
            return Self.pendingFIT(row)
        }
    }

    private static func pendingFIT(_ row: Row) -> FitnessPendingFITImport {
        let filename: String? = row["local_filename"]
        return FitnessPendingFITImport(
            id: row["id"],originalFilename: row["original_filename"],byteCount: row["byte_count"],
            status: FitnessImportStatus(rawValue: row["status"]) ?? .error,
            serverImportId: row["server_import_id"],activityId: row["activity_id"],
            sourceRecordId: row["source_record_id"],sourceRetained: (row["source_retained"] as Int) != 0,
            retryable: (row["retryable"] as Int) != 0,attempts: row["attempt_count"],
            lastError: row["last_error"],createdAt: FitnessDatabase.date(row["created_at"]) ?? .distantPast,
            updatedAt: FitnessDatabase.date(row["updated_at"]) ?? .distantPast,hasLocalCopy: filename != nil
        )
    }

    private func pendingFITDirectory() throws -> URL {
        guard let root = database.activeStoreURL?.deletingLastPathComponent() else {
            throw FitnessDatabaseError.notActive
        }
        let directory = root.appendingPathComponent("PendingFIT", isDirectory: true)
        try LocalFileProtection.prepareDirectory(directory, fileManager: fileManager)
        return directory
    }

    private static func isOwnedPendingFITFilename(_ filename: String) -> Bool {
        if isOwnedFinalFITFilename(filename) { return true }
        let suffix = ".staging"
        guard filename.hasPrefix("."), filename.hasSuffix(suffix) else { return false }
        let uuid = String(filename.dropFirst().dropLast(suffix.count))
        return uuid.count == 36
            && uuid == uuid.lowercased()
            && UUID(uuidString: uuid) != nil
    }

    private static func isOwnedFinalFITFilename(_ filename: String) -> Bool {
        let suffix = ".fit"
        guard filename.hasSuffix(suffix) else { return false }
        let uuid = String(filename.dropLast(suffix.count))
        return uuid.count == 36
            && uuid == uuid.lowercased()
            && UUID(uuidString: uuid) != nil
    }

    private func applyOptimisticContext(activityId: String, update: FitnessActivityContextUpdate) throws {
        guard var detail = try cachedDetail(activityId) else { return }
        if let title = update.title { detail.activity.title = title }
        detail.notes = update.notes
        detail.sessionRpe = update.sessionRpe
        detail.activity.workoutClassification = update.workoutClassification
        if let plannedId = update.plannedSessionId,
           detail.plannedSession?.id != plannedId {
            // Preserve only the explicit identity offline; the next detail refresh supplies metadata.
            detail.plannedSession = FitnessRemotePlannedSession(
                id: plannedId,sportKey: detail.activity.sportKey,title: "Linked plan",status: "accepted",
                scheduledStartUtc: nil,scheduledDate: nil,workoutVersionId: nil,
                trainingProgrammeId: nil,expectedDurationS: nil,expectedDistanceM: nil
            )
        } else if update.plannedSessionId == nil {
            detail.plannedSession = nil
        }
        if let gearIds = update.gearIds {
            let available = try cachedGear()
            detail.gear = available.filter { gearIds.contains($0.id) }
            detail.activity.gear = detail.gear
        }
        try cacheDetail(detail)
    }

    private func cacheWorkoutVersion(
        _ version: FitnessWorkoutVersionDTO,
        definitionId: String,
        db: Database,
        now: String
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO fitness_workout_definition_versions
                (id,workout_definition_id,version_number,title,purpose,estimated_duration_seconds,
                 estimated_distance_metres,structured_summary_json,version_source,created_at,accepted_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET accepted_at=COALESCE(excluded.accepted_at,accepted_at)
                """,
            arguments: [
                version.id,definitionId,version.versionNumber ?? 1,version.title,version.purpose,
                version.estimatedDurationS,version.estimatedDistanceM,
                try json(version.structuredSummary ?? [:]),version.versionSource,
                version.createdAt ?? now,version.acceptedAt,
            ]
        )
        try db.execute(sql: "DELETE FROM fitness_run_workout_steps WHERE workout_version_id=?", arguments: [version.id])
        try db.execute(sql: "DELETE FROM fitness_run_workout_cues WHERE workout_version_id=?", arguments: [version.id])
        try insertRunSteps(version.runSteps ?? [], versionId: version.id, parentId: nil, db: db)
        for cue in version.runCues ?? [] {
            try db.execute(
                sql: """
                    INSERT INTO fitness_run_workout_cues
                    (id,workout_version_id,step_id,sequence,trigger_type,trigger_value,short_text,spoken_text,priority)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    cue.id,version.id,cue.stepId,cue.sequence,cue.triggerType,cue.triggerValue,
                    cue.shortText,cue.spokenText,cue.priority,
                ]
            )
        }
    }

    private func insertRunSteps(
        _ steps: [FitnessRunWorkoutStep],
        versionId: String,
        parentId: String?,
        db: Database
    ) throws {
        for step in steps {
            try db.execute(
                sql: """
                    INSERT INTO fitness_run_workout_steps
                    (id,workout_version_id,parent_step_id,sequence,step_kind,repeat_count,duration_type,
                     duration_value,target_type,target_low,target_high,target_unit,intensity_label,
                     kilometre_index,display_name,instruction_text,mental_cue_text,spoken_cue_text,
                     allow_manual_advance,notes)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                arguments: [
                    step.id,versionId,parentId ?? step.parentStepId,step.sequence,step.stepKind,step.repeatCount,
                    step.durationType.rawValue,step.durationValue,step.targetType.rawValue,step.targetLow,
                    step.targetHigh,step.targetUnit,step.intensityLabel,step.kilometreIndex,
                    step.displayName,step.instructionText,step.mentalCueText,step.spokenCueText,
                    step.allowManualAdvance ?? false,step.notes,
                ]
            )
            try insertRunSteps(step.children ?? [], versionId: versionId, parentId: step.id, db: db)
        }
    }

    private func cachePayload<T: Encodable>(
        _ value: T,
        table: String,
        keyColumn: String,
        key: String
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO \(table)(\(keyColumn),payload_json,cached_at) VALUES (?,?,?)
                    ON CONFLICT(\(keyColumn)) DO UPDATE SET
                      payload_json=excluded.payload_json,cached_at=excluded.cached_at
                    """,
                arguments: [key,try json(value),FitnessDatabase.dateString(Date())]
            )
        }
    }

    private func cachedPayload<T: Decodable>(
        _ type: T.Type,
        table: String,
        keyColumn: String,
        key: String
    ) throws -> T? {
        let value = try database.read { db in
            try String.fetchOne(
                db, sql: "SELECT payload_json FROM \(table) WHERE \(keyColumn)=?", arguments: [key]
            )
        }
        guard let value else { return nil }
        return try decode(type, from: value)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        try decoder.decode(type, from: Data(value.utf8))
    }

    private static func safeFilename(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent
        return String(name.replacingOccurrences(of: "\0", with: "").prefix(240))
    }

    private static func streamCacheKey(
        activityId: String,
        clock: String,
        metrics: [String],
        fromOffsetMs: Int?,
        toOffsetMs: Int?,
        maxPoints: Int
    ) -> String {
        [
            activityId,clock,metrics.sorted().joined(separator: ","),
            String(fromOffsetMs ?? -1),String(toOffsetMs ?? -1),String(maxPoints),
        ].joined(separator: "|")
    }

    private static func analysisQueryKey(_ request: FitnessAnalysisQueryRequest) -> String {
        let filters = request.filters.sorted { $0.key < $1.key }.map {
            "\($0.key):\($0.operator.rawValue):\(analysisValueKey($0.value))"
        }.joined(separator: "&")
        return [
            request.measureKey,request.dimensionKey,request.chartTypeKey.rawValue,
            request.dateRange.start,request.dateRange.end,filters,
            request.comparisonKey ?? "",String(request.maxPoints),
        ].joined(separator: "|")
    }

    private static func analysisValueKey(_ value: JSONValue) -> String {
        switch value {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .array(let values): return values.map(analysisValueKey).joined(separator: ",")
        case .object: return "invalid-object"
        case .null: return "null"
        }
    }
}
