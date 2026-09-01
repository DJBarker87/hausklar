import Foundation

// MARK: - DTOs

/// Top-level data transfer object for the babysitter mode API response.
struct BabysitterDataDTO: Codable {
    let caregiverPack: BabysitterCaregiverPackDTO
    let children: [BabysitterChildDTO]
    let medicineSchedule: [BabysitterMedicineDTO]
    let activeNaps: [BabysitterNapDTO]
    let todaysEvents: [BabysitterEventDTO]
}

enum BabysitterCaregiverPackStatusDTO: String, Codable {
    case configured
    case incomplete
}

enum BabysitterMissingSectionDTO: String, Codable, Identifiable {
    case dailyRoutine = "daily_routine"
    case emergencyContacts = "emergency_contacts"
    case wifiPassword = "wifi_password"
    case houseRules = "house_rules"
    case allergies

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dailyRoutine:
            return "Daily Routine".localized
        case .emergencyContacts:
            return "Emergency Contacts".localized
        case .wifiPassword:
            return "WiFi Password".localized
        case .houseRules:
            return "House Rules".localized
        case .allergies:
            return "Allergies".localized
        }
    }
}

/// Parent-entered handover details. The UI treats the pack as usable only when
/// the API marks it configured and all required data is present.
struct BabysitterCaregiverPackDTO: Codable {
    let status: BabysitterCaregiverPackStatusDTO
    let missingSections: [BabysitterMissingSectionDTO]
    let dailyRoutine: BabysitterRoutineDTO?
    let emergencyContacts: [BabysitterContactDTO]
    let importantInfo: BabysitterInfoDTO?

    var isConfigured: Bool {
        status == .configured
            && missingSections.isEmpty
            && dailyRoutine != nil
            && !emergencyContacts.isEmpty
            && importantInfo != nil
    }
}

/// Child information for babysitter mode.
struct BabysitterChildDTO: Codable, Identifiable {
    var id: String { name }
    let name: String
    let age: Int
    let dateOfBirth: String
    let notes: String?
}

/// Daily routine schedule for babysitter mode.
struct BabysitterRoutineDTO: Codable {
    let breakfast: String
    let lunch: String
    let dinner: String
    let napTime: String
    let bath: String
    let stories: String
    let bedtime: String
}

/// Medicine schedule item for babysitter mode.
struct BabysitterMedicineDTO: Codable, Identifiable {
    var id: String { "\(childName)_\(medicineName)" }
    let childName: String
    let medicineName: String
    let dosageNotes: String?
    let lastGivenAt: String?
    let lastGivenBy: String?
    let nextDoseAllowedAt: String?
    let minHoursBetween: Double
}

/// Emergency contact for babysitter mode.
struct BabysitterContactDTO: Codable, Identifiable {
    var id: String { name }
    let name: String
    let phone: String
}

/// Active nap for babysitter mode.
struct BabysitterNapDTO: Codable, Identifiable {
    var id: String { childName + startedAt }
    let childName: String
    let startedAt: String
    let location: String?
}

/// Today's event for babysitter mode.
struct BabysitterEventDTO: Codable, Identifiable {
    var id: String { title + startTime }
    let title: String
    let startTime: String
    let endTime: String
}

/// Important household information for babysitter mode.
struct BabysitterInfoDTO: Codable {
    let wifiPassword: String
    let houseRules: String
    let allergies: String
}

// MARK: - Authoritative caregiver handover

struct CaregiverHouseDTO: Codable {
    let id: String?
    let address: String?
    let wifiName: String?
    let wifiPassword: String?
    let emergencyInstructions: String?
    let houseInstructions: String?
    let dogInstructions: String?
}

struct CaregiverChildProfileDTO: Codable, Identifiable {
    var id: String { childId }
    let childId: String
    let childName: String
    let careNotes: String?
    let allergies: String?
    let food: String?
    let comfort: String?
    let toileting: String?
    let bedtime: String?
}

struct CaregiverContactRecordDTO: Codable, Identifiable {
    let id: String
    let name: String
    let phone: String
    let relationship: String?
    let priority: Int
}

struct CaregiverReadinessItemDTO: Codable, Identifiable {
    var id: String { key }
    let key: String
    let label: String
    let ready: Bool
    let childId: String?
}

struct CaregiverReadinessDTO: Codable {
    let ready: Bool
    let completeCount: Int
    let totalCount: Int
    let items: [CaregiverReadinessItemDTO]
}

struct CaregiverHandoverDTO: Codable {
    let id: String?
    let house: CaregiverHouseDTO
    let children: [CaregiverChildProfileDTO]
    let contacts: [CaregiverContactRecordDTO]
    let readiness: CaregiverReadinessDTO
    let updatedAt: String?
}

struct CaregiverBookingDTO: Codable, Identifiable {
    let id: String
    let label: String
    let startsAt: String
    let expiresAt: String
    let childIds: [String]
    let childNames: [String]
    var status: String
    let createdAt: String
    let revokedAt: String?
    let lastAccessedAt: String?
}

struct CaregiverCreatedBookingDTO: Codable, Identifiable {
    let id: String
    let label: String
    let startsAt: String
    let expiresAt: String
    let childIds: [String]
    let childNames: [String]
    let status: String
    let createdAt: String
    let revokedAt: String?
    let lastAccessedAt: String?
    let shareUrl: String

    var booking: CaregiverBookingDTO {
        CaregiverBookingDTO(
            id: id,
            label: label,
            startsAt: startsAt,
            expiresAt: expiresAt,
            childIds: childIds,
            childNames: childNames,
            status: status,
            createdAt: createdAt,
            revokedAt: revokedAt,
            lastAccessedAt: lastAccessedAt
        )
    }

    var url: URL? { URL(string: shareUrl) }
}

struct CaregiverHouseDraft {
    var address = ""
    var wifiName = ""
    var wifiPassword = ""
    var emergencyInstructions = ""
    var houseInstructions = ""
    var dogInstructions = ""
}

struct CaregiverChildDraft: Identifiable {
    var id: String { childId }
    let childId: String
    let childName: String
    var careNotes = ""
    var allergies = ""
    var food = ""
    var comfort = ""
    var toileting = ""
    var bedtime = ""
}

struct CaregiverContactDraft: Identifiable {
    let id: UUID
    var name: String
    var phone: String
    var relationship: String

    init(id: UUID = UUID(), name: String = "", phone: String = "", relationship: String = "") {
        self.id = id
        self.name = name
        self.phone = phone
        self.relationship = relationship
    }
}

private struct CaregiverHouseUpdate: Encodable {
    let address: String?
    let wifiName: String?
    let wifiPassword: String?
    let emergencyInstructions: String?
    let houseInstructions: String?
    let dogInstructions: String?
}

private struct CaregiverChildUpdate: Encodable {
    let childId: String
    let careNotes: String?
    let allergies: String?
    let food: String?
    let comfort: String?
    let toileting: String?
    let bedtime: String?
}

private struct CaregiverContactUpdate: Encodable {
    let name: String
    let phone: String
    let relationship: String?
    let priority: Int
}

private struct CaregiverHandoverUpdate: Encodable {
    let house: CaregiverHouseUpdate
    let children: [CaregiverChildUpdate]
    let contacts: [CaregiverContactUpdate]
}

private struct CaregiverBookingCreate: Encodable {
    let label: String
    let startsAt: String
    let expiresAt: String
    let childIds: [String]
}

private struct CaregiverRevokeResponse: Decodable {
    let status: String
    let bookingId: String
}

// MARK: - ViewModel

/// Parent-facing editor for a truthful handover and time-boxed, revocable access.
/// The one-time share URL deliberately stays only in memory.
@MainActor
final class BabysitterViewModel: ObservableObject {
    @Published var handover: CaregiverHandoverDTO?
    @Published var bookings: [CaregiverBookingDTO] = []
    @Published var houseDraft = CaregiverHouseDraft()
    @Published var childDrafts: [CaregiverChildDraft] = []
    @Published var contactDrafts: [CaregiverContactDraft] = []
    @Published var createdBooking: CaregiverCreatedBookingDTO?
    @Published var isLoading = false
    @Published var workingID: String?
    @Published var errorMessage: String?
    @Published var noticeMessage: String?

    private let apiClient: APIClient

    init(apiClient: APIClient = .shared) {
        self.apiClient = apiClient
    }

    func loadData() async {
        isLoading = true
        errorMessage = nil
        do {
            async let handoverRequest: CaregiverHandoverDTO = apiClient.get("/babysitter/handover")
            async let bookingsRequest: [CaregiverBookingDTO] = apiClient.get("/babysitter/bookings")
            let (fetchedHandover, fetchedBookings) = try await (handoverRequest, bookingsRequest)
            handover = fetchedHandover
            bookings = fetchedBookings
            applyDraft(fetchedHandover)
        } catch {
            errorMessage = message(for: error, fallback: "The babysitter handover could not be loaded.")
        }
        isLoading = false
    }

    @discardableResult
    func saveHandover() async -> Bool {
        let invalidContact = contactDrafts.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if invalidContact != nil {
            errorMessage = "Each emergency contact needs a name and phone number."
            return false
        }
        workingID = "handover"
        errorMessage = nil
        let body = CaregiverHandoverUpdate(
            house: CaregiverHouseUpdate(
                address: optional(houseDraft.address),
                wifiName: optional(houseDraft.wifiName),
                wifiPassword: optional(houseDraft.wifiPassword),
                emergencyInstructions: optional(houseDraft.emergencyInstructions),
                houseInstructions: optional(houseDraft.houseInstructions),
                dogInstructions: optional(houseDraft.dogInstructions)
            ),
            children: childDrafts.map {
                CaregiverChildUpdate(
                    childId: $0.childId,
                    careNotes: optional($0.careNotes),
                    allergies: optional($0.allergies),
                    food: optional($0.food),
                    comfort: optional($0.comfort),
                    toileting: optional($0.toileting),
                    bedtime: optional($0.bedtime)
                )
            },
            contacts: contactDrafts.enumerated().map { index, contact in
                CaregiverContactUpdate(
                    name: contact.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    phone: contact.phone.trimmingCharacters(in: .whitespacesAndNewlines),
                    relationship: optional(contact.relationship),
                    priority: index
                )
            }
        )
        do {
            let saved: CaregiverHandoverDTO = try await apiClient.put("/babysitter/handover", body: body)
            handover = saved
            applyDraft(saved)
            noticeMessage = saved.readiness.ready
                ? "The handover is ready to share."
                : "Saved. The readiness list shows what is still needed."
            workingID = nil
            return true
        } catch {
            errorMessage = message(for: error, fallback: "The handover could not be saved.")
            workingID = nil
            return false
        }
    }

    func createBooking(label: String, startsAt: Date, expiresAt: Date, childIDs: Set<String>) async {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else {
            errorMessage = "Add a name for this booking."
            return
        }
        guard !childIDs.isEmpty else {
            errorMessage = "Choose at least one child."
            return
        }
        guard expiresAt > startsAt else {
            errorMessage = "The booking must end after it starts."
            return
        }
        guard expiresAt > Date() else {
            errorMessage = "Caregiver access must end in the future."
            return
        }
        guard expiresAt.timeIntervalSince(startsAt) <= 7 * 24 * 60 * 60 else {
            errorMessage = "Caregiver access cannot last longer than seven days."
            return
        }
        let missing = missingReadiness(for: childIDs)
        guard missing.isEmpty else {
            errorMessage = "Finish the handover first: \(missing.prefix(3).joined(separator: ", "))."
            return
        }
        workingID = "booking"
        errorMessage = nil
        let formatter = ISO8601DateFormatter()
        let body = CaregiverBookingCreate(
            label: cleanLabel,
            startsAt: formatter.string(from: startsAt),
            expiresAt: formatter.string(from: expiresAt),
            childIds: childDrafts.filter { childIDs.contains($0.childId) }.map(\.childId)
        )
        do {
            let created: CaregiverCreatedBookingDTO = try await apiClient.post("/babysitter/bookings", body: body)
            bookings.insert(created.booking, at: 0)
            createdBooking = created
        } catch {
            errorMessage = message(for: error, fallback: "The private sitter link could not be created.")
        }
        workingID = nil
    }

    func revoke(_ booking: CaregiverBookingDTO) async {
        workingID = booking.id
        errorMessage = nil
        do {
            let response: CaregiverRevokeResponse = try await apiClient.post(
                "/babysitter/bookings/\(booking.id)/revoke"
            )
            guard response.status == "revoked", response.bookingId == booking.id else {
                throw APIError.networkError(URLError(.badServerResponse))
            }
            if let index = bookings.firstIndex(where: { $0.id == booking.id }) {
                bookings[index].status = "revoked"
            }
            if createdBooking?.id == booking.id { createdBooking = nil }
            noticeMessage = "Caregiver access revoked."
        } catch {
            errorMessage = message(for: error, fallback: "Caregiver access could not be revoked.")
        }
        workingID = nil
    }

    func missingReadiness(for childIDs: Set<String>) -> [String] {
        guard let handover else { return ["Handover details"] }
        return handover.readiness.items
            .filter { item in
                !item.ready && (item.childId.map(childIDs.contains) ?? true)
            }
            .map(\.label)
    }

    func addContact() {
        contactDrafts.append(CaregiverContactDraft())
    }

    func removeContacts(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            contactDrafts.remove(at: index)
        }
    }

    func discardDraftChanges() {
        if let handover { applyDraft(handover) }
    }

    private func applyDraft(_ handover: CaregiverHandoverDTO) {
        houseDraft = CaregiverHouseDraft(
            address: handover.house.address ?? "",
            wifiName: handover.house.wifiName ?? "",
            wifiPassword: handover.house.wifiPassword ?? "",
            emergencyInstructions: handover.house.emergencyInstructions ?? "",
            houseInstructions: handover.house.houseInstructions ?? "",
            dogInstructions: handover.house.dogInstructions ?? ""
        )
        childDrafts = handover.children.map {
            CaregiverChildDraft(
                childId: $0.childId,
                childName: $0.childName,
                careNotes: $0.careNotes ?? "",
                allergies: $0.allergies ?? "",
                food: $0.food ?? "",
                comfort: $0.comfort ?? "",
                toileting: $0.toileting ?? "",
                bedtime: $0.bedtime ?? ""
            )
        }
        contactDrafts = handover.contacts.map {
            CaregiverContactDraft(name: $0.name, phone: $0.phone, relationship: $0.relationship ?? "")
        }
    }

    private func optional(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private func message(for error: Error, fallback: String) -> String {
        (error as? APIError)?.errorDescription ?? fallback
    }
}
