import Foundation

// MARK: - Health Record DTOs
// Contract for /health-record/{child_id}/... — vaccinations, growth
// centiles and a GP-ready summary. Records and reminders only, never medical advice.

// MARK: Shared status

/// Status for vaccination records. Drives the tint and icon.
enum HealthStatus: String, Codable {
    case given
    case overdue
    case due
    case upcoming
}

/// Fallback disclaimer used when the server omits one, so an absent field never
/// removes the reassurance banner (and never fails the whole decode).
enum HealthDisclaimer {
    static let fallback = "Records and reminders only, not medical advice. Speak to your GP or health visitor with any concerns."
}

// MARK: - Vaccinations

struct VaccinationItemDTO: Codable, Identifiable {
    let key: String
    let name: String
    let dueAgeLabel: String
    let dueDate: String?
    let status: HealthStatus
    let givenOn: String?
    /// Missing on older servers; those items are the routine schedule.
    let isStandard: Bool?

    var id: String { key }
    var isAdditional: Bool { isStandard == false }

    var dueDateDisplay: String? {
        guard let dueDate, let date = ISODateParser.parse(dueDate) else { return nil }
        return ISODateParser.dateOnly(from: date)
    }
}

struct VaccinationsResponseDTO: Codable {
    let childId: String?
    let childName: String?
    let ageMonths: Double?
    let vaccinations: [VaccinationItemDTO]
    // Optional so an omitted disclaimer never fails the whole decode.
    let disclaimer: String?
}

/// JSON body for POST /health-record/{child_id}/vaccinations.
struct VaccinationRecordRequest: Encodable {
    let vaccineKey: String
    let givenOn: String
}

/// JSON body for a family-entered vaccine outside the routine schedule.
struct AdditionalVaccinationRecordRequest: Encodable {
    let vaccineName: String
    let givenOn: String
}

/// JSON body for recording completed or ongoing sick days from Health.
struct HealthIllnessRecordRequest: Encodable {
    let childId: String
    let startedAt: String
    let endedAt: String?
    let notes: String?
}

// MARK: - Growth centiles

struct GrowthCentilePointDTO: Codable, Identifiable {
    let date: String
    let ageMonths: Double?
    let heightCm: Double?
    let weightKg: Double?
    let heightCentile: Double?
    let weightCentile: Double?

    var id: String { date }
}

struct ReferenceCurvePointDTO: Codable, Identifiable {
    let ageMonths: Int
    let p2: Double
    let p9: Double
    let p25: Double
    let p50: Double
    let p75: Double
    let p91: Double
    let p98: Double

    var id: Int { ageMonths }
}

struct GrowthCentilesResponseDTO: Codable {
    let childId: String?
    let childName: String?
    let sex: String?
    let measurements: [GrowthCentilePointDTO]
    let weightReference: [ReferenceCurvePointDTO]
    let heightReference: [ReferenceCurvePointDTO]
    // Optional so an omitted disclaimer never fails the whole decode.
    let disclaimer: String?
    let note: String?
}

/// JSON body for PATCH /health-record/{child_id}/sex.
struct SexUpdateRequest: Encodable {
    let sex: String
}

/// JSON body for adding a measurement without leaving the child's health record.
struct HealthGrowthRecordRequest: Encodable {
    let childId: String
    let date: String
    let heightCm: Double?
    let weightKg: Double?
    let headCircumferenceCm: Double?
    let notes: String?
}

// MARK: - GP summary

struct SummaryIllnessDTO: Codable, Identifiable {
    let id: String?
    let startedAt: String
    let endedAt: String?
    let notes: String?

    /// Stable identity even when the server omits an id.
    var identity: String { id ?? startedAt }
}

struct SummaryTemperatureDTO: Codable, Identifiable {
    let recordedAt: String
    let valueCelsius: Double

    var id: String { recordedAt }
}

struct SummaryDoseDTO: Codable, Identifiable {
    let givenAt: String
    let name: String
    let doseAmount: String?

    var id: String { givenAt + name }
}

struct SummaryResponseDTO: Codable {
    let childId: String?
    let childName: String?
    let since: String
    let until: String
    let illnesses: [SummaryIllnessDTO]
    let temperatures: [SummaryTemperatureDTO]
    let medicineDoses: [SummaryDoseDTO]
    let report: String
    // Optional so an omitted disclaimer never fails the whole decode.
    let disclaimer: String?
}
