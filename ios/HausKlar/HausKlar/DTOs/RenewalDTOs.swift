import SwiftUI

// MARK: - Renewal DTOs
// Contract for /renewals/ — household renewals and expiries so nothing lapses unnoticed.

/// Traffic-light status for a renewal, driven server-side from due date and reminder window.
enum RenewalStatus: String, Codable {
    case overdue
    case dueSoon = "due_soon"
    case upcoming

    /// Badge/accent colour. Overdue is urgent, due-soon is a nudge, upcoming is calm.
    var color: Color {
        switch self {
        case .overdue: return .red
        case .dueSoon: return .orange
        case .upcoming: return .green
        }
    }

    var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .dueSoon: return "Due soon"
        case .upcoming: return "Upcoming"
        }
    }
}

/// Category of a renewal. Drives the icon and grouping.
enum RenewalCategory: String, Codable, CaseIterable, Identifiable {
    case document
    case vehicle
    case insurance
    case subscription
    case utility
    case membership
    case medical
    case other

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .document: return "doc.text.fill"
        case .vehicle: return "car.fill"
        case .insurance: return "shield.lefthalf.filled"
        case .subscription: return "arrow.triangle.2.circlepath"
        case .utility: return "bolt.fill"
        case .membership: return "person.example_34a8c6ad.fill"
        case .medical: return "cross.case.fill"
        case .other: return "tag.fill"
        }
    }

    var label: String {
        switch self {
        case .document: return "Document"
        case .vehicle: return "Vehicle"
        case .insurance: return "Insurance"
        case .subscription: return "Subscription"
        case .utility: return "Utility"
        case .membership: return "Membership"
        case .medical: return "Medical"
        case .other: return "Other"
        }
    }
}

struct RenewalDTO: Codable, Identifiable {
    let id: String
    let title: String
    // Unknown categories are tolerated by falling back to `.other` in `categoryValue`.
    let category: String
    let dueDate: String
    let daysUntil: Int
    let status: RenewalStatus
    let recurrenceMonths: Int?
    let costPence: Int?
    let reminderDaysBefore: Int
    let sourceDocumentId: String?
    var sourceDocument: SourceDocumentDTO? = nil
    var provider: String? = nil
    var reference: String? = nil
    var actionUrl: String? = nil
    var comparisonUrl: String? = nil
    var contactUrl: String? = nil
    var financeCommitmentId: String? = nil
    var paymentHandling: String? = nil
    var showInCalendar: Bool? = nil
    var showInTasks: Bool? = nil
    var responsibleUserId: String? = nil
    var responsibleUserName: String? = nil
    var remindersEnabled: Bool? = nil
    var escalateAfterDays: Int? = nil
    var checklist: [RenewalChecklistItemDTO]? = nil
    var history: [RenewalHistoryItemDTO]? = nil
    var previousCostPence: Int? = nil
    var costChangePence: Int? = nil
    let notes: String?
    let createdAt: String

    /// The category as a typed value, defaulting to `.other` for anything unexpected.
    var categoryValue: RenewalCategory {
        RenewalCategory(rawValue: category) ?? .other
    }

    /// "£42.00" or nil when no cost recorded.
    var costDisplay: String? {
        guard let costPence else { return nil }
        return String(format: "£%.2f", Double(costPence) / 100)
    }

    /// "in 12 days", "Today", "Yesterday", "3 days ago".
    var dueLabel: String {
        switch daysUntil {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        case -1: return "1 day overdue"
        case let d where d > 1: return "in \(d) days"
        default: return "\(-daysUntil) days overdue"
        }
    }

    /// Human-readable due date, e.g. "12 July 2026".
    var dueDateDisplay: String {
        guard let date = ISODateParser.parse(dueDate) else { return dueDate }
        return ISODateParser.dateOnly(from: date)
    }

    /// "Renews every 12 months" or nil for one-off renewals.
    var recurrenceLabel: String? {
        guard let months = recurrenceMonths else { return nil }
        if months == 12 { return "Renews yearly" }
        if months == 1 { return "Renews monthly" }
        return "Renews every \(months) months"
    }
}

struct RenewalChecklistItemDTO: Codable, Identifiable {
    let id: String
    let title: String
    let checkedAt: String?
    let position: Int
}

struct RenewalHistoryItemDTO: Codable, Identifiable {
    let id: String
    let outcome: String
    let dueDate: String
    let decidedAt: String
    let costPence: Int?
    let nextDueDate: String?
    let notes: String?
}

struct RenewalDraftPreviewDTO: Codable {
    let title: String?
    let category: String
    let dueDate: String?
    let recurrenceMonths: Int?
    let costPence: Int?
    let provider: String?
    let reference: String?
    let actionUrl: String?
    let sourceDocumentId: String?
    let uncertainFields: [String]
}

struct RenewalDraftPreviewRequest: Encodable {
    let documentId: String
}

struct RenewalChecklistItemCreateRequest: Encodable {
    let title: String
}

struct RenewalChecklistItemUpdateRequest: Encodable {
    let checked: Bool
}

struct RenewalDecisionRequest: Encodable {
    let outcome: String
    let nextDueDate: String?
    let costPence: Int?
    let notes: String?
}

/// JSON body for POST /renewals/.
struct RenewalCreateRequest: Encodable {
    let title: String
    let category: String
    let dueDate: String
    let recurrenceMonths: Int?
    let costPence: Int?
    let reminderDaysBefore: Int?
    let sourceDocumentId: String?
    let provider: String?
    let reference: String?
    let actionUrl: String?
    let comparisonUrl: String?
    let contactUrl: String?
    let notes: String?
    let includeInHouseholdFinance: Bool
    let paymentHandling: String
    let showInCalendar: Bool
    let showInTasks: Bool
    let responsibleUserId: String?
    let remindersEnabled: Bool
    let escalateAfterDays: Int?
    let checklist: [String]
}

/// JSON body for PATCH /renewals/{id}. Nil fields are omitted (partial update).
struct RenewalUpdateRequest: Encodable {
    let title: String?
    let category: String?
    let dueDate: String?
    let recurrenceMonths: Int?
    let costPence: Int?
    let reminderDaysBefore: Int?
    let sourceDocumentId: String?
    let provider: String?
    let reference: String?
    let actionUrl: String?
    let comparisonUrl: String?
    let contactUrl: String?
    let notes: String?
    let includeInHouseholdFinance: Bool
    let paymentHandling: String
    let showInCalendar: Bool
    let showInTasks: Bool
    let responsibleUserId: String?
    let remindersEnabled: Bool
    let escalateAfterDays: Int?

    enum CodingKeys: String, CodingKey {
        case title, category, dueDate, recurrenceMonths, costPence
        case reminderDaysBefore, sourceDocumentId, provider, reference
        case actionUrl, comparisonUrl, contactUrl, notes
        case includeInHouseholdFinance, paymentHandling, showInCalendar
        case showInTasks, responsibleUserId, remindersEnabled, escalateAfterDays
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(dueDate, forKey: .dueDate)
        try container.encodeIfPresent(recurrenceMonths, forKey: .recurrenceMonths)
        try container.encodeIfPresent(costPence, forKey: .costPence)
        try container.encodeIfPresent(reminderDaysBefore, forKey: .reminderDaysBefore)
        try container.encodeIfPresent(sourceDocumentId, forKey: .sourceDocumentId)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(reference, forKey: .reference)
        try container.encodeIfPresent(actionUrl, forKey: .actionUrl)
        try container.encodeIfPresent(comparisonUrl, forKey: .comparisonUrl)
        try container.encodeIfPresent(contactUrl, forKey: .contactUrl)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(includeInHouseholdFinance, forKey: .includeInHouseholdFinance)
        try container.encode(paymentHandling, forKey: .paymentHandling)
        try container.encode(showInCalendar, forKey: .showInCalendar)
        try container.encode(showInTasks, forKey: .showInTasks)
        try container.encodeIfPresent(responsibleUserId, forKey: .responsibleUserId)
        try container.encode(remindersEnabled, forKey: .remindersEnabled)
        try container.encodeIfPresent(escalateAfterDays, forKey: .escalateAfterDays)
    }
}

// MARK: - Library loan DTOs

struct LibraryOverviewDTO: Codable {
    let accounts: [LibraryAccountDTO]
    let loans: [LibraryLoanDTO]

    static let empty = LibraryOverviewDTO(accounts: [], loans: [])
}

struct LibraryAccountDTO: Codable, Identifiable {
    let id: String
    let provider: String
    let label: String
    let cardLastFour: String
    let syncEnabled: Bool
    let reminderDaysBefore: Int
    let status: String
    let lastSyncAt: String?
    let lastSuccessAt: String?
    let nextSyncAt: String?
    let errorMessage: String?

    var statusLabel: String {
        switch status {
        case "connected": return "Connected"
        case "needs_attention": return "Reconnect needed"
        case "temporarily_unavailable": return "Temporarily unavailable"
        default: return "Check pending"
        }
    }
}

enum LibraryLoanStatus: String, Codable {
    case overdue
    case dueSoon = "due_soon"
    case current

    var color: Color {
        switch self {
        case .overdue: return .red
        case .dueSoon: return .orange
        case .current: return .accentColor
        }
    }
}

struct LibraryLoanDTO: Codable, Identifiable {
    let id: String
    let accountId: String
    let accountLabel: String
    let title: String
    let author: String?
    let materialFormat: String?
    let dueDate: String
    let daysUntil: Int
    let status: LibraryLoanStatus
    let providerStatus: String?
    let renewable: Bool?
    let renewalCount: Int?
    let renewUrl: String?

    var renewalURL: URL? {
        guard daysUntil <= 7,
              let renewUrl,
              let url = URL(string: renewUrl),
              url.scheme == "https",
              url.host?.lowercased() == "library.example.invalid",
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              url.path.hasPrefix("/cgi-bin/spydus.exe/") else { return nil }
        return url
    }

    var dueLabel: String {
        switch daysUntil {
        case let value where value < -1: return "\(-value) days overdue"
        case -1: return "1 day overdue"
        case 0: return "Due back today"
        case 1: return "Due back tomorrow"
        default: return "Due back in \(daysUntil) days"
        }
    }

    var dueDateDisplay: String {
        guard let date = ISODateParser.parse(dueDate) else { return dueDate }
        return ISODateParser.dateOnly(from: date)
    }
}

struct LibraryAccountCreateRequest: Encodable {
    let label: String
    let cardNumber: String
    let pin: String
    let reminderDaysBefore: Int
}
