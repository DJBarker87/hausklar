import Foundation
import SwiftData

/// Unified health data record from multiple sources (Strava, Withings, Apple Health).
@Model
final class HealthRecord {
    @Attribute(.unique) var id: String
    /// Data source: strava, withings, apple_health
    var source: String
    /// Data type: weight, sleep, run, cycle, etc.
    var dataType: String
    /// Primary metric value (e.g. 75.5 for weight in kg).
    var value: Double
    /// Unit of measurement: kg, hours, km, etc.
    var unit: String
    var recordedAt: Date
    /// JSON-encoded extra data (pace, calories, heart rate zones, etc.)
    var metadata: String?
    var createdAt: Date
    var updatedAt: Date
    var createdBy: String?
    var deletedAt: Date?

    init(
        id: String = UUID().uuidString,
        source: String = "",
        dataType: String = "",
        value: Double = 0.0,
        unit: String = "",
        recordedAt: Date = Date(),
        metadata: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        createdBy: String? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.dataType = dataType
        self.value = value
        self.unit = unit
        self.recordedAt = recordedAt
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdBy = createdBy
        self.deletedAt = deletedAt
    }
}
