import Foundation
import GRDB

/// This extension is isolated to FitnessRepository's single actor. Its context
/// is never used independently of that facade, preserving call-site serialization.
extension FitnessRepository {
    // MARK: Nutrition and body

    func foods(search: String = "") throws -> [FitnessFood] {
        try context.read { db in
            let term = "%\(search.trimmingCharacters(in: .whitespacesAndNewlines))%"
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT f.*, v.kcal_per_100g, v.default_serving_grams
                    FROM fitness_foods f
                    JOIN fitness_food_versions v ON v.id = f.current_version_id
                    WHERE f.deleted_at IS NULL AND f.is_archived = 0
                      AND (? = '%%' OR f.name LIKE ? OR COALESCE(f.brand, '') LIKE ?)
                    ORDER BY f.is_favourite DESC, f.name COLLATE NOCASE
                    """,
                arguments: [term, term, term]
            ).map(Self.food)
        }
    }

    @discardableResult
    func createFood(
        name: String,
        brand: String?,
        kcalPer100g: Double?,
        defaultServingGrams: Double?
    ) throws -> FitnessFood {
        let now = Date()
        let food = FitnessFood(
            id: UUID().uuidString,
            versionId: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            brand: Self.trimmedOrNil(brand),
            kcalPer100g: kcalPer100g,
            defaultServingGrams: defaultServingGrams,
            isFavourite: false,
            isArchived: false,
            revision: 0,
            updatedAt: now
        )
        let payload = FoodPayload(
            id: food.id,
            name: food.name,
            brand: food.brand,
            householdShared: false,
            favourite: false,
            active: true,
            version: FoodVersionPayload(
                id: food.versionId,
                referenceAmount: 100,
                referenceUnit: "g",
                caloriesKcal: kcalPer100g,
                sourceType: "manual",
                confidence: kcalPer100g == nil ? "unknown" : "measured"
            )
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_foods
                    (id, current_version_id, name, brand, revision, client_updated_at, origin_device_id)
                    VALUES (?, ?, ?, ?, 0, ?, ?)
                    """,
                arguments: [
                    food.id, food.versionId, food.name, food.brand, FitnessDatabase.dateString(now), try context.verifiedDeviceId(),
                ]
            )
            try db.execute(
                sql: """
                    INSERT INTO fitness_food_versions
                    (id, food_id, kcal_per_100g, default_serving_grams, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [food.versionId, food.id, kcalPer100g, defaultServingGrams, FitnessDatabase.dateString(now)]
            )
            try enqueue(context: context, db, type: .food, id: food.id, baseRevision: nil, payload: payload, now: now)
        }
        return food
    }

    @discardableResult
    func logFood(
        foodId: String,
        amountGrams: Double?,
        meal: FitnessMeal,
        at loggedAt: Date = Date()
    ) throws -> FitnessFoodLogEntry {
        try context.write { db in
            let foodId = try resolvedId(type: .food, id: foodId, db: db)
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT f.*, v.kcal_per_100g, v.default_serving_grams
                        FROM fitness_foods f JOIN fitness_food_versions v ON v.id = f.current_version_id
                        WHERE f.id = ? AND f.deleted_at IS NULL
                        """,
                    arguments: [foodId]
                )
            else { throw FitnessRepositoryError.missingFood }
            let food = Self.food(row)
            guard let grams = amountGrams ?? food.defaultServingGrams, grams > 0 else {
                throw FitnessRepositoryError.invalidAmount
            }
            let kcal = food.kcalPer100g.map { $0 * grams / 100 }
            let now = Date()
            let entry = FitnessFoodLogEntry(
                id: UUID().uuidString,
                foodId: food.id,
                foodVersionId: food.versionId,
                foodName: food.name,
                loggedAt: loggedAt,
                nutritionDate: FitnessCalculations.nutritionDate(for: loggedAt),
                meal: meal,
                amountGrams: grams,
                kcal: kcal,
                revision: 0,
                updatedAt: now
            )
            try insertFoodLog(context: context, entry, db: db)
            let payload = FoodLogPayload(
                id: entry.id,
                foodVersionId: food.versionId,
                loggedAtUtc: loggedAt,
                localTimezone: TimeZone.current.identifier,
                mealKey: meal.rawValue,
                enteredAmount: grams,
                enteredUnit: "g",
                canonicalAmount: grams,
                canonicalUnit: "g",
                measurementQuality: amountGrams == nil ? "standard_serving" : "weighed"
            )
            try enqueue(context: context, db, type: .foodLogEntry, id: entry.id, baseRevision: nil, payload: payload, now: now)
            return entry
        }
    }

    func diary(on date: Date = Date()) throws -> FitnessDiarySummary {
        let nutritionDate = FitnessCalculations.nutritionDate(for: date)
        return try context.read { db in
            let entries = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_food_log_entries
                    WHERE nutrition_date = ? AND deleted_at IS NULL
                    ORDER BY logged_at DESC
                    """,
                arguments: [nutritionDate]
            ).map(Self.foodLog)
            return FitnessDiarySummary(entries: entries, totalKcal: entries.compactMap(\.kcal).reduce(0, +))
        }
    }

    @discardableResult
    func repeatFoodLog(_ sourceId: String, at date: Date = Date()) throws -> FitnessFoodLogEntry {
        let source: FitnessFoodLogEntry = try context.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM fitness_food_log_entries WHERE id = ? AND deleted_at IS NULL",
                    arguments: [sourceId]
                )
            else { throw FitnessRepositoryError.missingFoodLog }
            return Self.foodLog(row)
        }
        guard let foodId = source.foodId else { throw FitnessRepositoryError.missingFood }
        return try logFood(foodId: foodId, amountGrams: source.amountGrams, meal: source.meal, at: date)
    }

    @discardableResult
    func addWeight(_ weightKg: Double, measuredAt: Date = Date()) throws -> FitnessBodyMeasurement {
        try saveBodyMeasurement(
            metricKey: "body.weight_kg", value: weightKg, unitKey: "kg",
            notes: nil, measuredAt: measuredAt
        )
    }

    @discardableResult
    func saveBodyMeasurement(
        id: String = UUID().uuidString,
        metricKey: String,
        value: Double,
        unitKey: String,
        notes: String?,
        measuredAt: Date = Date(),
        measurementQuality: String = "measured"
    ) throws -> FitnessBodyMeasurement {
        let cleanMetric = metricKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanUnit = unitKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            cleanMetric.range(
                of: #"^body\.[a-z0-9_]{1,100}$"#, options: .regularExpression
            ) != nil
        else { throw FitnessRepositoryError.invalidBodyMeasurement }
        guard value.isFinite, value > 0, !cleanUnit.isEmpty, cleanUnit.count <= 40,
            (cleanNotes?.count ?? 0) <= 4_000
        else {
            throw FitnessRepositoryError.invalidBodyMeasurement
        }
        let now = Date()
        let existing: (revision: Int, source: FitnessMeasurementSource)? = try context.read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT revision,source FROM fitness_body_measurements WHERE id=? AND deleted_at IS NULL",
                    arguments: [id]
                )
            else { return nil }
            return (
                row["revision"],
                FitnessMeasurementSource(rawValue: row["source"]) ?? .manual
            )
        }
        guard existing?.source != .healthKit && existing?.source != .imported else {
            throw FitnessRepositoryError.importedBodyMeasurementReadOnly
        }
        let measurement = FitnessBodyMeasurement(
            id: id,
            metricKey: cleanMetric,
            measuredAt: measuredAt,
            value: value,
            unitKey: cleanUnit,
            notes: cleanNotes?.isEmpty == true ? nil : cleanNotes,
            measurementQuality: measurementQuality,
            source: .manual,
            isCanonical: true,
            revision: existing?.revision ?? 0,
            updatedAt: now
        )
        let payload = BodyMeasurementPayload(
            id: measurement.id,
            metricKey: cleanMetric,
            measuredAtUtc: measuredAt,
            localTimezone: TimeZone.current.identifier,
            value: value,
            unitKey: cleanUnit,
            measurementQuality: measurementQuality,
            canonicalState: "canonical",
            notes: measurement.notes
        )
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_body_measurements
                    (id,measured_at,weight_kg,source,is_canonical,revision,client_updated_at,
                     origin_device_id,metric_key,value_number,unit_key,notes,measurement_quality,
                     canonical_state,deleted_at)
                    VALUES (?,?,?,'manual',1,?,?, ?,?,?,?,?,?,'canonical',NULL)
                    ON CONFLICT(id) DO UPDATE SET
                      measured_at=excluded.measured_at,weight_kg=excluded.weight_kg,
                      source='manual',is_canonical=1,client_updated_at=excluded.client_updated_at,
                      metric_key=excluded.metric_key,value_number=excluded.value_number,
                      unit_key=excluded.unit_key,notes=excluded.notes,
                      measurement_quality=excluded.measurement_quality,
                      canonical_state='canonical',deleted_at=NULL
                    """,
                arguments: [
                    measurement.id, FitnessDatabase.dateString(measuredAt), value,
                    existing?.revision ?? 0, FitnessDatabase.dateString(now), try context.verifiedDeviceId(),
                    cleanMetric, value, cleanUnit, measurement.notes, measurementQuality,
                ]
            )
            try enqueue(
                context: context,
                db, type: .bodyMeasurement, id: measurement.id,
                baseRevision: existing?.revision, payload: payload, now: now
            )
        }
        return measurement
    }

    func bodyMeasurements(
        limit: Int = 90,
        includeDuplicates: Bool = false,
        metricKey: String? = "body.weight_kg"
    ) throws -> [FitnessBodyMeasurement] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT m.*,
                           s.transport_key AS detail_transport_key,
                           s.origin_provider_key AS detail_origin_provider_key,
                           s.source_namespace AS detail_source_namespace,
                           s.source_device_identifier AS detail_source_device_identifier,
                           s.state AS detail_source_state
                    FROM fitness_body_measurements m
                    LEFT JOIN fitness_external_source_records s ON s.id=m.source_record_id
                    WHERE m.deleted_at IS NULL AND (? OR m.is_canonical=1)
                      AND (? IS NULL OR m.metric_key=?)
                    ORDER BY m.measured_at DESC LIMIT ?
                    """,
                arguments: [includeDuplicates, metricKey, metricKey, limit]
            ).map(Self.bodyMeasurement)
        }
    }

    /// Reads chart history by metric with descending keyset pagination. This
    /// keeps the hot path on `fitness_body_measurement_metric_time_idx`, joins
    /// source attribution once, and never materialises unrelated body metrics.
    func bodyMeasurementsForHistory(
        metricKeys: [String], startAt: Date? = nil, endAt: Date? = nil,
        pageSize: Int = 500, maximumRows: Int = 10_000
    ) throws -> [FitnessBodyMeasurement] {
        guard !metricKeys.isEmpty, maximumRows > 0 else { return [] }
        return try context.read { db in
            let pageLimit = max(1, min(pageSize, 1_000))
            let rowLimit = max(1, min(maximumRows, 50_000))
            let placeholders = Array(repeating: "?", count: metricKeys.count).joined(separator: ",")
            var result: [FitnessBodyMeasurement] = []
            var cursor: (date: String, id: String)?
            repeat {
                var conditions = [
                    "m.deleted_at IS NULL", "m.is_canonical=1",
                    "m.metric_key IN (\(placeholders))", "m.value_number IS NOT NULL",
                ]
                var arguments = StatementArguments(metricKeys)
                if let startAt {
                    conditions.append("m.measured_at>=?")
                    arguments += [FitnessDatabase.dateString(startAt)]
                }
                if let endAt {
                    conditions.append("m.measured_at<=?")
                    arguments += [FitnessDatabase.dateString(endAt)]
                }
                if let cursor {
                    conditions.append("(m.measured_at<? OR (m.measured_at=? AND m.id<?))")
                    arguments += [cursor.date, cursor.date, cursor.id]
                }
                let requested = min(pageLimit, rowLimit - result.count)
                arguments += [requested]
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.id,m.metric_key,m.measured_at,m.value_number,m.weight_kg,
                               m.unit_key,m.notes,m.measurement_quality,m.source,m.is_canonical,
                               m.revision,m.client_updated_at,m.source_record_id,m.canonical_state,
                               m.duplicate_of_measurement_id,m.manual_canonical_override,
                               m.transport_key,m.origin_provider_key,m.source_namespace,
                               src.transport_key AS detail_transport_key,
                               src.origin_provider_key AS detail_origin_provider_key,
                               src.source_namespace AS detail_source_namespace,
                               src.source_device_identifier AS detail_source_device_identifier,
                               src.state AS detail_source_state
                        FROM fitness_body_measurements m
                        LEFT JOIN fitness_external_source_records src ON src.id=m.source_record_id
                        WHERE \(conditions.joined(separator:" AND "))
                        ORDER BY m.measured_at DESC,m.id DESC LIMIT ?
                        """, arguments: arguments
                )
                result.append(contentsOf: rows.map(Self.bodyMeasurement))
                guard rows.count == requested, let last = rows.last else { break }
                cursor = (last["measured_at"], last["id"])
            } while result.count < rowLimit
            return result
        }
    }

    func sourcePriorities(metricKey: String? = nil) throws -> [FitnessSourcePriorityDTO] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM fitness_source_priorities
                    WHERE deleted_at IS NULL AND (? IS NULL OR metric_key=?)
                    ORDER BY metric_key,priority DESC,origin_provider_key,transport_key,source_namespace
                    """, arguments: [metricKey, metricKey]
            ).map {
                FitnessSourcePriorityDTO(
                    id: $0["id"], metricKey: $0["metric_key"],
                    originProviderKey: $0["origin_provider_key"],
                    transportKey: $0["transport_key"], sourceNamespace: $0["source_namespace"],
                    priority: $0["priority"], revision: $0["revision"],
                    updatedAt: $0["updated_at"], deletedAt: $0["deleted_at"]
                )
            }
        }
    }

    func cacheSourcePriority(_ value: FitnessSourcePriorityDTO) throws {
        try context.write { db in
            try db.execute(
                sql: """
                    INSERT INTO fitness_source_priorities
                    (id,metric_key,origin_provider_key,transport_key,source_namespace,priority,
                     revision,updated_at,deleted_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(metric_key,origin_provider_key,transport_key,source_namespace)
                    DO UPDATE SET id=excluded.id,priority=excluded.priority,
                      revision=excluded.revision,updated_at=excluded.updated_at,
                      deleted_at=excluded.deleted_at
                    """,
                arguments: [
                    value.id, value.metricKey, value.originProviderKey, value.transportKey,
                    value.sourceNamespace, value.priority, value.revision ?? 0,
                    value.updatedAt ?? FitnessDatabase.dateString(Date()), value.deletedAt,
                ]
            )
        }
    }

    func applyCanonicalOverride(_ response: FitnessBodyMeasurementCanonicalOverrideResponse) throws {
        let now = FitnessDatabase.dateString(Date())
        try context.write { db in
            for id in response.groupMemberIds {
                let isCanonical = id == response.canonicalMeasurementId
                try db.execute(
                    sql: """
                        UPDATE fitness_body_measurements
                        SET is_canonical=?, canonical_state=?, duplicate_of_measurement_id=?,
                            manual_canonical_override=?, client_updated_at=?
                        WHERE id=? AND deleted_at IS NULL
                        """,
                    arguments: [
                        isCanonical, isCanonical ? "canonical" : "duplicate",
                        isCanonical ? nil : response.canonicalMeasurementId,
                        response.manualOverride && isCanonical, now, id,
                    ]
                )
            }
        }
    }

    func readinessHistory(limit: Int = 30) throws -> [FitnessReadinessHistoryItem] {
        try context.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.*,s.title AS activity_title,s.session_rpe,s.performance
                    FROM fitness_session_checkins c
                    LEFT JOIN fitness_strength_sessions s ON s.id=c.session_id
                    WHERE c.kind='readiness' AND c.value IS NOT NULL AND c.deleted_at IS NULL
                    ORDER BY c.recorded_at DESC LIMIT ?
                    """, arguments: [limit]
            ).compactMap { row in
                guard let recorded = FitnessDatabase.date(row["recorded_at"]) else { return nil }
                return FitnessReadinessHistoryItem(
                    id: row["id"], recordedAt: recorded, value: row["value"],
                    isRetrospective: (row["retrospective"] as Int) != 0,
                    activityTitle: row["activity_title"], sessionRPE: row["session_rpe"],
                    performance: row["performance"]
                )
            }
        }
    }

}
