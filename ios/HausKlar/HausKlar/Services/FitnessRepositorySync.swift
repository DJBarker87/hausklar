import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {

    func pendingMutations(limit: Int = 100) throws -> [FitnessPendingMutation] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT o.* FROM fitness_outbox o
                    WHERE o.entity_type<>?
                      AND NOT EXISTS (
                        SELECT 1 FROM fitness_private_file_uploads u
                        WHERE u.asset_kind='nutrition_label'
                          AND u.dependent_mutation_id=o.mutation_id
                          AND u.upload_acknowledged=0
                      )
                    ORDER BY o.created_at_client,o.mutation_id LIMIT ?
                    """,
                arguments: [FitnessEntityType.progressPhoto.rawValue, limit]
            ).map { row in
                let payloadData = Data((row["payload_json"] as String).utf8)
                let payload = try JSONDecoder().decode([String: JSONValue].self, from: payloadData)
                return FitnessPendingMutation(
                    mutationId: row["mutation_id"],
                    entityType: row["entity_type"],
                    entityId: row["entity_id"],
                    operation: row["operation"],
                    payloadSchemaVersion: row["payload_schema_version"],
                    baseRevision: row["base_revision"],
                    payload: payload,
                    createdAtClient: row["created_at_client"]
                )
            }
        }
    }

    func syncCursor() throws -> Int {
        try context.read { db in
            Int(try String.fetchOne(db, sql: "SELECT value FROM fitness_metadata WHERE key = 'sync_cursor'") ?? "0") ?? 0
        }
    }

    func markSyncAttempt(_ mutationIds: [String], error: String?) throws {
        guard !mutationIds.isEmpty else { return }
        let now = FitnessDatabase.dateString(Date())
        try context.write { db in
            for id in mutationIds {
                try db.execute(
                    sql: """
                        UPDATE fitness_outbox SET attempt_count = attempt_count + 1,
                        last_attempt_at = ?, last_error = ? WHERE mutation_id = ?
                        """,
                    arguments: [now, error, id]
                )
            }
        }
    }

    func applySync(_ response: FitnessSyncResponse, sentMutationIds: Set<String>) throws {
        try context.write { db in
            try applyMutationReceipts(response, sentMutationIds: sentMutationIds, db: db)
            try rollBackAbandonedRejections(db: db)
            // Removals this device has queued but not had accepted yet. A change
            // generated before such a removal reached the server would otherwise
            // clear its local tombstone and put the record back on screen, which
            // reads as a removal that refused to stick.
            let queuedRemovalRows = try Row.fetchAll(
                db,
                sql: "SELECT entity_type,entity_id FROM fitness_outbox WHERE operation='delete'"
            )
            let queuedRemovals = Set(queuedRemovalRows.map { row -> String in
                let entityType: String = row["entity_type"]
                let entityId: String = row["entity_id"]
                return "\(entityType)|\(entityId)"
            })
            for change in response.changes {
                let data = try context.encode(change.data)
                try db.execute(
                    sql: """
                        INSERT INTO fitness_remote_entities
                        (entity_type, entity_id, revision, operation, payload_json, changed_at, sequence)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                          revision = excluded.revision, operation = excluded.operation,
                          payload_json = excluded.payload_json, changed_at = excluded.changed_at,
                          sequence = excluded.sequence
                        WHERE excluded.sequence >= fitness_remote_entities.sequence
                        """,
                    arguments: [
                        change.entityType, change.entityId, change.revision, change.operation,
                        String(decoding: data, as: UTF8.self), change.changedAt, change.sequence,
                    ]
                )
                try applyRemoteChange(change, db: db)
                if change.operation != "delete",
                    queuedRemovals.contains("\(change.entityType)|\(change.entityId)") {
                    try applyRemoteChange(
                        FitnessSyncChange(
                            sequence: change.sequence, entityType: change.entityType,
                            entityId: change.entityId, revision: change.revision,
                            operation: "delete", data: nil, changedAt: change.changedAt
                        ),
                        db: db
                    )
                }
            }
            for redirect in response.redirects {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_redirects(entity_type, source_id, target_id, updated_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(entity_type, source_id) DO UPDATE SET
                          target_id = excluded.target_id, updated_at = excluded.updated_at
                        """,
                    arguments: [redirect.entityType, redirect.sourceId, redirect.targetId, FitnessDatabase.dateString(Date())]
                )
                let heldMutationCount =
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                        arguments: [redirect.entityType, redirect.sourceId]
                    ) ?? 0
                if heldMutationCount > 0 {
                    // A direct mutation against a merged alias must never be silently
                    // retargeted. Remove it explicitly and leave a durable notice; child
                    // references resolve through the redirect cache on their next write.
                    let attemptedPayload = try String.fetchOne(
                        db,
                        sql: """
                            SELECT payload_json FROM fitness_outbox
                            WHERE entity_type=? AND entity_id=?
                            ORDER BY created_at_client DESC LIMIT 1
                            """,
                        arguments: [redirect.entityType, redirect.sourceId]
                    )
                    try db.execute(
                        sql: "DELETE FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
                        arguments: [redirect.entityType, redirect.sourceId]
                    )
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO fitness_sync_notices
                            (id,kind,message,entity_type,entity_id,created_at,
                             previous_values_json,target_entity_id,server_backed)
                            VALUES (?, 'canonical_identity_changed', ?, ?, ?, ?, ?, ?, 0)
                            """,
                        arguments: [
                            "redirect-\(redirect.entityType)-\(redirect.sourceId)",
                            "A pending change was not applied because this record was merged. Review the canonical record before editing again.",
                            redirect.entityType, redirect.sourceId, FitnessDatabase.dateString(Date()),
                            attemptedPayload, redirect.targetId,
                        ]
                    )
                }
            }
            for notice in response.notices {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_sync_notices
                        (id,kind,message,entity_type,entity_id,created_at,
                         previous_values_json,target_entity_id,server_backed)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                        ON CONFLICT(id) DO UPDATE SET
                          message=excluded.message,
                          previous_values_json=excluded.previous_values_json,
                          target_entity_id=excluded.target_entity_id,
                          server_backed=1
                        """,
                    arguments: [
                        notice.id, notice.kind ?? "info", notice.message,
                        notice.entityType, notice.entityId, notice.createdAt ?? FitnessDatabase.dateString(Date()),
                        notice.previousValues.map { values in
                            String(decoding: try context.encode(values), as: UTF8.self)
                        },
                        notice.targetEntityId,
                    ]
                )
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO fitness_metadata(key, value) VALUES ('sync_cursor', ?)",
                arguments: [String(response.nextCursor)]
            )
        }
        try context.markFirstPostMigrationSyncComplete()
    }

    /// Returns a record the server refused to the last state the server did
    /// report. A record the server never held has no such state, so it leaves
    /// the device's own views instead of sitting there as a phantom entry. The
    /// attempted values stay recoverable in `fitness_sync_rejections`.
    private func rollBackOptimisticRecord(
        entityType: String, entityId: String, db: Database
    ) throws {
        let stillQueued = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM fitness_outbox WHERE entity_type=? AND entity_id=?",
            arguments: [entityType, entityId]
        ) ?? 0
        guard stillQueued == 0 else { return }
        let remote = try Row.fetchOne(
            db,
            sql: "SELECT * FROM fitness_remote_entities WHERE entity_type=? AND entity_id=?",
            arguments: [entityType, entityId]
        )
        guard let remote else {
            try applyRemoteChange(
                FitnessSyncChange(
                    sequence: 0, entityType: entityType, entityId: entityId,
                    revision: 0, operation: "delete", data: nil,
                    changedAt: FitnessDatabase.dateString(Date())
                ),
                db: db
            )
            return
        }
        let payloadJSON: String = remote["payload_json"]
        let payload = try? JSONDecoder().decode(
            [String: JSONValue].self, from: Data(payloadJSON.utf8)
        )
        let operation: String = remote["operation"]
        try applyRemoteChange(
            FitnessSyncChange(
                sequence: remote["sequence"], entityType: entityType, entityId: entityId,
                revision: remote["revision"],
                operation: payload == nil ? "delete" : operation,
                data: payload, changedAt: remote["changed_at"]
            ),
            db: db
        )
    }

    /// Repairs records left behind by a rejection this app dropped before it
    /// rolled optimistic state back. Only records with no queued mutation and
    /// no server state are touched, so re-running it changes nothing.
    private func rollBackAbandonedRejections(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT DISTINCT r.entity_type AS entity_type, r.entity_id AS entity_id
                FROM fitness_sync_rejections r
                WHERE r.resolved_at IS NULL
                  AND NOT EXISTS (
                    SELECT 1 FROM fitness_outbox o
                    WHERE o.entity_type=r.entity_type AND o.entity_id=r.entity_id
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM fitness_remote_entities e
                    WHERE e.entity_type=r.entity_type AND e.entity_id=r.entity_id
                  )
                """
        )
        for row in rows {
            let entityType: String = row["entity_type"]
            let entityId: String = row["entity_id"]
            try rollBackOptimisticRecord(entityType: entityType, entityId: entityId, db: db)
        }
    }

    /// Replaces the sync-managed owner graph in one SQLite transaction after
    /// the server reports that the incremental cursor has fallen outside its
    /// retained change history. Pending mutations and protected-file staging
    /// tables are deliberately not cleared; their optimistic values are
    /// replayed over the snapshot before the new cursor becomes visible.
    func applySnapshot(
        _ snapshot: FitnessSnapshotResponse,
        syncResponse: FitnessSyncResponse,
        sentMutationIds: Set<String>
    ) throws {
        try context.write { db in
            try applyMutationReceipts(syncResponse, sentMutationIds: sentMutationIds, db: db)

            let pending = try Row.fetchAll(
                db, sql: "SELECT * FROM fitness_outbox ORDER BY created_at_client,mutation_id"
            ).map { row -> FitnessPendingMutation in
                let payload: String = row["payload_json"]
                return FitnessPendingMutation(
                    mutationId: row["mutation_id"], entityType: row["entity_type"],
                    entityId: row["entity_id"], operation: row["operation"],
                    payloadSchemaVersion: row["payload_schema_version"],
                    baseRevision: row["base_revision"],
                    payload: try JSONDecoder().decode([String: JSONValue].self, from: Data(payload.utf8)),
                    createdAtClient: row["created_at_client"]
                )
            }

            try clearSnapshotManagedState(db)

            for entity in snapshot.entities {
                let payload = String(decoding: try context.encode(entity.data), as: UTF8.self)
                try db.execute(
                    sql: """
                        INSERT INTO fitness_remote_entities
                        (entity_type,entity_id,revision,operation,payload_json,changed_at,sequence)
                        VALUES (?,?,?,'upsert',?,?,?)
                        """,
                    arguments: [
                        entity.entityType, entity.entityId, entity.revision, payload,
                        snapshot.generatedAt, snapshot.nextCursor,
                    ]
                )
                try applyRemoteChange(
                    FitnessSyncChange(
                        sequence: snapshot.nextCursor, entityType: entity.entityType,
                        entityId: entity.entityId, revision: entity.revision,
                        operation: "upsert", data: entity.data, changedAt: snapshot.generatedAt
                    ),
                    db: db
                )
            }

            for redirect in snapshot.redirects {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_redirects(entity_type,source_id,target_id,updated_at)
                        VALUES (?,?,?,?)
                        ON CONFLICT(entity_type,source_id) DO UPDATE SET
                          target_id=excluded.target_id,updated_at=excluded.updated_at
                        """,
                    arguments: [redirect.entityType, redirect.sourceId, redirect.targetId, snapshot.generatedAt]
                )
            }

            let redirects = Dictionary(
                uniqueKeysWithValues: snapshot.redirects.map {
                    ("\($0.entityType)|\($0.sourceId)", $0.targetId)
                }
            )
            for mutation in pending {
                // Do not paint an obsolete alias over the canonical snapshot.
                // The mutation stays queued and the review notice makes the
                // attempted values recoverable.
                if let target = redirects["\(mutation.entityType)|\(mutation.entityId)"] {
                    let attempted = String(decoding: try context.encode(mutation.payload), as: UTF8.self)
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO fitness_sync_notices
                            (id,kind,message,entity_type,entity_id,created_at,
                             previous_values_json,target_entity_id,server_backed)
                            VALUES (?, 'canonical_identity_changed', ?, ?, ?, ?, ?, ?, 0)
                            """,
                        arguments: [
                            "snapshot-redirect-\(mutation.entityType)-\(mutation.entityId)",
                            "A queued change targets a record that has since been merged. Review the canonical record before retrying.",
                            mutation.entityType, mutation.entityId, snapshot.generatedAt, attempted, target,
                        ]
                    )
                    continue
                }
                try applyRemoteChange(
                    FitnessSyncChange(
                        sequence: snapshot.nextCursor, entityType: mutation.entityType,
                        entityId: mutation.entityId, revision: mutation.baseRevision ?? 0,
                        operation: mutation.operation, data: mutation.operation == "delete" ? nil : mutation.payload,
                        changedAt: mutation.createdAtClient
                    ),
                    db: db
                )
            }

            for notice in syncResponse.notices {
                try db.execute(
                    sql: """
                        INSERT INTO fitness_sync_notices
                        (id,kind,message,entity_type,entity_id,created_at,
                         previous_values_json,target_entity_id,server_backed)
                        VALUES (?,?,?,?,?,?,?,?,1)
                        ON CONFLICT(id) DO UPDATE SET
                          message=excluded.message,previous_values_json=excluded.previous_values_json,
                          target_entity_id=excluded.target_entity_id,server_backed=1
                        """,
                    arguments: [
                        notice.id, notice.kind ?? "info", notice.message, notice.entityType,
                        notice.entityId, notice.createdAt ?? snapshot.generatedAt,
                        notice.previousValues.map {
                            String(decoding: try context.encode($0), as: UTF8.self)
                        }, notice.targetEntityId,
                    ]
                )
            }

            // This is intentionally last: a failed replacement transaction can
            // never advertise a cursor for records it did not fully materialise.
            try db.execute(
                sql: "INSERT OR REPLACE INTO fitness_metadata(key,value) VALUES ('sync_cursor',?)",
                arguments: [String(snapshot.nextCursor)]
            )
        }
        try context.markFirstPostMigrationSyncComplete()
    }

    func syncRejections(includeResolved: Bool = false) throws -> [FitnessMutationRejectionRecord] {
        try context.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_sync_rejections
                    WHERE (? = 1 OR resolved_at IS NULL)
                    ORDER BY rejected_at DESC, mutation_id
                    """,
                arguments: [includeResolved ? 1 : 0]
            )
            return try rows.map { row in
                let payloadJSON: String = row["payload_json"]
                let payload = try JSONDecoder().decode(
                    [String: JSONValue].self, from: Data(payloadJSON.utf8)
                )
                let summaryJSON: String? = row["target_summary_json"]
                let summary = try summaryJSON.map {
                    try JSONDecoder().decode([String: JSONValue].self, from: Data($0.utf8))
                }
                guard
                    let disposition = FitnessMutationRejectionDisposition(
                        rawValue: row["disposition"]
                    )
                else { throw FitnessSyncError.malformedResponse }
                return FitnessMutationRejectionRecord(
                    mutation: FitnessPendingMutation(
                        mutationId: row["mutation_id"], entityType: row["entity_type"],
                        entityId: row["entity_id"], operation: row["operation"],
                        payloadSchemaVersion: row["payload_schema_version"],
                        baseRevision: row["base_revision"], payload: payload,
                        createdAtClient: row["created_at_client"]
                    ),
                    code: row["code"], message: row["message"],
                    disposition: disposition, targetEntityId: row["target_entity_id"],
                    targetSummary: summary, serverNoticeId: row["server_notice_id"],
                    attemptCount: row["attempt_count"], lastAttemptAt: row["last_attempt_at"],
                    rejectedAt: row["rejected_at"]
                )
            }
        }
    }

    /// Retryable rejections require an explicit user action. Merely running the
    /// background sync loop never puts a rejected mutation back into the outbox.
    @discardableResult
    func retryRejectedMutation(_ mutationId: String) throws -> String? {
        try context.write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM fitness_sync_rejections
                        WHERE mutation_id=? AND resolved_at IS NULL AND disposition='retryable'
                        """,
                    arguments: [mutationId]
                )
            else { return nil }
            let retryMutationId = UUID().uuidString
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO fitness_outbox
                    (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                     base_revision,payload_json,created_at_client,attempt_count,last_attempt_at,last_error)
                    VALUES (?,?,?,?,?,?,?,?,?,?,NULL)
                    """,
                arguments: [
                    retryMutationId, row["entity_type"], row["entity_id"], row["operation"],
                    row["payload_schema_version"], row["base_revision"], row["payload_json"],
                    FitnessDatabase.dateString(Date()), 0, Optional<String>.none,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads SET dependent_mutation_id=?
                    WHERE dependent_mutation_id=?
                    """,
                arguments: [retryMutationId, mutationId]
            )
            try db.execute(
                sql: "UPDATE fitness_sync_rejections SET resolved_at=? WHERE mutation_id=?",
                arguments: [FitnessDatabase.dateString(Date()), mutationId]
            )
            let noticeId: String? = row["server_notice_id"]
            if let noticeId {
                try db.execute(
                    sql: "UPDATE fitness_sync_notices SET dismissed_at=? WHERE id=?",
                    arguments: [FitnessDatabase.dateString(Date()), noticeId]
                )
            }
            return retryMutationId
        }
    }

    private func clearSnapshotManagedState(_ db: Database) throws {
        let tables = [
            "fitness_remote_entities", "fitness_redirects",
            "fitness_training_phase_goal_links", "fitness_training_programme_goal_links",
            "fitness_workout_version_sets", "fitness_workout_version_exercises",
            "fitness_run_workout_cues", "fitness_run_workout_steps",
            "fitness_workout_definition_versions", "fitness_planned_sets",
            "fitness_planned_session_exercises", "fitness_strength_set_components",
            "fitness_strength_set_groups", "fitness_strength_session_exercises",
            "fitness_goal_relationships", "fitness_training_phases",
            "fitness_training_programmes", "fitness_workout_definitions",
            "fitness_planned_sessions", "fitness_strength_sessions",
            "fitness_session_checkins", "fitness_body_issues",
            "fitness_food_servings", "fitness_food_versions", "fitness_foods",
            "fitness_recipe_versions", "fitness_recipes", "fitness_meal_templates",
            "fitness_nutrition_targets", "fitness_food_log_entries",
            "fitness_body_measurements", "fitness_exercise_setups", "fitness_exercises",
            "fitness_sleep_segments", "fitness_sleep_sessions", "fitness_recovery_observations",
            "fitness_source_priorities", "fitness_external_source_records",
            "fitness_progress_photos", "fitness_gear_items", "fitness_goals",
            "fitness_nutrition_settings",
            "fitness_cycle_period_starts", "fitness_cycle_settings",
        ]
        for table in tables where try db.tableExists(table) {
            try db.execute(sql: "DELETE FROM \(table)")
        }
    }

    func notices() throws -> [FitnessSyncNotice] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT n.*,r.mutation_id AS rejected_mutation_id,
                           r.disposition AS rejection_disposition
                    FROM fitness_sync_notices n
                    LEFT JOIN fitness_sync_rejections r
                      ON r.server_notice_id=n.id AND r.resolved_at IS NULL
                    WHERE n.dismissed_at IS NULL
                    ORDER BY n.created_at DESC
                    """
            ).map { row in
                let dispositionValue: String? = row["rejection_disposition"]
                return FitnessSyncNotice(
                    id: row["id"], kind: row["kind"], message: row["message"],
                    entityType: row["entity_type"], entityId: row["entity_id"], createdAt: row["created_at"],
                    previousValues: try (row["previous_values_json"] as String?).map { json in
                        try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
                    },
                    targetEntityId: row["target_entity_id"],
                    isServerNotice: (row["server_backed"] as Int? ?? 0) == 1,
                    rejectedMutationId: row["rejected_mutation_id"],
                    rejectionDisposition: dispositionValue.flatMap(
                        FitnessMutationRejectionDisposition.init(rawValue:)
                    )
                )
            }
        }
    }

    private func applyMutationReceipts(
        _ response: FitnessSyncResponse,
        sentMutationIds: Set<String>,
        db: Database
    ) throws {
        let rejected = Dictionary(
            response.rejectedMutations
                .filter { sentMutationIds.contains($0.mutationId) }
                .map { ($0.mutationId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = FitnessDatabase.dateString(Date())

        for (mutationId, rejection) in rejected {
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM fitness_outbox WHERE mutation_id=?",
                    arguments: [mutationId]
                )
            else { continue }
            let entityType: String = row["entity_type"]
            let entityId: String = row["entity_id"]
            let payloadJSON: String = row["payload_json"]
            let summaryJSON = try rejection.targetSummary.map {
                String(decoding: try context.encode($0), as: UTF8.self)
            }
            let message = rejection.actionableMessage
            let noticeId = rejection.noticeId ?? "rejection-\(mutationId)"
            let attemptCount: Int = row["attempt_count"]
            try db.execute(
                sql: """
                    INSERT INTO fitness_sync_rejections
                    (mutation_id,entity_type,entity_id,operation,payload_schema_version,
                     base_revision,payload_json,created_at_client,attempt_count,last_attempt_at,
                     code,message,disposition,target_entity_id,target_summary_json,
                     server_notice_id,rejected_at,resolved_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
                    ON CONFLICT(mutation_id) DO UPDATE SET
                      attempt_count=excluded.attempt_count,
                      last_attempt_at=excluded.last_attempt_at,
                      code=excluded.code,message=excluded.message,
                      disposition=excluded.disposition,
                      target_entity_id=excluded.target_entity_id,
                      target_summary_json=excluded.target_summary_json,
                      server_notice_id=excluded.server_notice_id,
                      rejected_at=excluded.rejected_at,resolved_at=NULL
                    """,
                arguments: [
                    mutationId, entityType, entityId, row["operation"],
                    row["payload_schema_version"], row["base_revision"], payloadJSON,
                    row["created_at_client"], attemptCount + 1, now,
                    rejection.code, message, rejection.disposition.rawValue,
                    rejection.targetId, summaryJSON, noticeId, now,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads
                       SET state='failed',last_error=?
                     WHERE asset_kind='nutrition_label' AND dependent_mutation_id=?
                    """,
                arguments: [message, mutationId]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_sync_notices
                    (id,kind,message,entity_type,entity_id,created_at,
                     previous_values_json,target_entity_id,server_backed)
                    VALUES (?,?,?,?,?,?,?,?,0)
                    ON CONFLICT(id) DO UPDATE SET
                      kind=excluded.kind,message=excluded.message,
                      entity_type=excluded.entity_type,entity_id=excluded.entity_id,
                      previous_values_json=excluded.previous_values_json,
                      target_entity_id=excluded.target_entity_id,dismissed_at=NULL
                    """,
                arguments: [
                    noticeId, rejection.code, message, entityType, entityId, now,
                    payloadJSON, rejection.targetId,
                ]
            )
            try db.execute(
                sql: "DELETE FROM fitness_outbox WHERE mutation_id=?",
                arguments: [mutationId]
            )
            // The optimistic record this mutation wrote must not outlive it.
            // Leaving it behind is what made rejected food entries sit in the
            // diary for good, doubling a meal the server only ever accepted once.
            try rollBackOptimisticRecord(entityType: entityType, entityId: entityId, db: db)
        }

        for ackId in response.ackedMutationIds
        where sentMutationIds.contains(ackId) && rejected[ackId] == nil {
            try db.execute(
                sql: """
                    UPDATE fitness_private_file_uploads
                       SET metadata_acknowledged=1,
                           state=CASE WHEN upload_acknowledged=1 THEN 'acknowledged' ELSE state END,
                           last_error=NULL
                     WHERE asset_kind='nutrition_label' AND dependent_mutation_id=?
                    """,
                arguments: [ackId]
            )
            try db.execute(
                sql: "DELETE FROM fitness_outbox WHERE mutation_id=?",
                arguments: [ackId]
            )
        }
    }

    func dismissNotice(_ id: String) throws {
        try context.write { db in
            let now = FitnessDatabase.dateString(Date())
            try db.execute(
                sql: "UPDATE fitness_sync_notices SET dismissed_at=? WHERE id=?",
                arguments: [now, id]
            )
            try db.execute(
                sql: """
                    UPDATE fitness_sync_rejections SET resolved_at=?
                    WHERE server_notice_id=? AND resolved_at IS NULL
                    """,
                arguments: [now, id]
            )
        }
    }

}
