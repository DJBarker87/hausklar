import Foundation
import SwiftData
import SwiftUI
import os

// MARK: - Medicine DTOs

/// Represents a medicine type (e.g., Calpol, Nurofen) with safety constraints.
struct MedicineTypeDTO: Codable, Identifiable {
    let id: String
    let name: String
    let minHoursBetweenDoses: Double
    let maxDoses24h: Int
    let notes: String?
    let color: String?
    let defaultDoseAmount: String?
    let childId: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, notes, color
        case minHoursBetweenDoses
        case maxDoses24h = "maxDoses24H"
        case defaultDoseAmount
        case childId
        case createdAt
    }
}

/// A safety warning returned by the API when dose timing or count limits are breached.
typealias SafetyWarningDTO = MedicineSafetyWarningDTO

/// A dose record bundled with any safety warnings that were active at the time it was logged.
struct DoseWithWarningsDTO: Codable, Identifiable {
    var id: String { dose.id }
    let dose: MedicineDoseDTO
    let warnings: [SafetyWarningDTO]
}

/// Result of a pre-dose safety check against the API.
struct SafetyCheckDTO: Codable {
    let safe: Bool
    let warnings: [SafetyWarningDTO]
    let nextSafeAt: String?
}

/// Lightweight child DTO used for the child selector.
struct ChildDTO: Codable, Identifiable {
    let id: String
    let name: String
    let dateOfBirth: String
}

// MARK: - Request Bodies

/// Request body for logging a new dose.
struct LogDoseRequest: Encodable, Equatable {
    let id: String
    let medicineTypeId: String?
    let childId: String
    let givenAt: String
    let doseAmount: String?
    let medicineName: String?
    let notes: String?

    private enum CodingKeys: String, CodingKey {
        case id, medicineTypeId, childId, givenAt, doseAmount, medicineName, notes
    }

    /// Encode optional fields explicitly as JSON null so the foreground request
    /// and the durable sync payload represent the same complete operation.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(medicineTypeId, forKey: .medicineTypeId)
        try values.encode(childId, forKey: .childId)
        try values.encode(givenAt, forKey: .givenAt)
        try values.encode(doseAmount, forKey: .doseAmount)
        try values.encode(medicineName, forKey: .medicineName)
        try values.encode(notes, forKey: .notes)
    }
}

/// Request body for creating a new medicine type.
struct CreateMedicineTypeRequest: Encodable, Equatable {
    let id: String
    let name: String
    let minHoursBetweenDoses: Double
    let maxDoses24h: Int
    let notes: String?
    let color: String?
    let defaultDoseAmount: String?
    let childId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, notes, color
        case minHoursBetweenDoses = "min_hours_between_doses"
        case maxDoses24h = "max_doses_24h"
        case defaultDoseAmount = "default_dose_amount"
        case childId = "child_id"
    }
}

struct UpdateMedicineTypeRequest: Encodable {
    let name: String
    let minHoursBetweenDoses: Double
    let maxDoses24h: Int
    let notes: String?
    let color: String?
    let defaultDoseAmount: String?
    let childId: String?

    enum CodingKeys: String, CodingKey {
        case name, notes, color
        case minHoursBetweenDoses = "min_hours_between_doses"
        case maxDoses24h = "max_doses_24h"
        case defaultDoseAmount = "default_dose_amount"
        case childId = "child_id"
    }
}

struct UpdateMedicineDoseRequest: Encodable {
    let givenAt: String
    let doseAmount: String?
    let clearDoseAmount: Bool
    let medicineName: String?
    let notes: String?
    let clearNotes: Bool
}

// MARK: - MedicineViewModel

/// ViewModel for the Medicine tracking view.
/// Medicine is SAFETY-CRITICAL. This ViewModel ensures warnings are always surfaced
/// and never silently suppressed.
@MainActor
final class MedicineViewModel: ObservableObject {

    private enum LocalPersistenceError: LocalizedError {
        case invalidRemoteDose
        case missingLocalRecord
        case storage(String)

        var errorDescription: String? {
            switch self {
            case .invalidRemoteDose:
                return "HausKlar refused an invalid medicine dose returned by the server."
            case .missingLocalRecord:
                return "The local medicine record could not be found."
            case .storage(let detail):
                return "Medicine history could not be saved on this device: \(detail)"
            }
        }
    }

    struct OfflineSafetyHistory {
        let previousDose: Date?
        let followingDose: Date?
        let rollingWindowDoses: [Date]
    }

    typealias OfflineSafetyHistoryLoader = (
        ModelContext,
        String,
        String,
        Date
    ) throws -> OfflineSafetyHistory

    // MARK: - Published State

    @Published var medicineTypes: [MedicineTypeDTO] = []
    @Published var recentDoses: [MedicineDoseDTO] = []
    @Published var selectedChildId: String?
    @Published var children: [ChildDTO] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showingLogDose = false
    @Published var showingAddType = false
    @Published var editingMedicineType: MedicineTypeDTO?
    @Published var editingDose: MedicineDoseDTO?
    @Published var recentlyDeletedDose: MedicineDoseDTO?
    @Published var lastDoseWarnings: [SafetyWarningDTO] = []
    @Published var showWarnings = false
    @Published var activeIllness: IllnessDTO?

    // MARK: - Log Dose Form

    @Published var selectedMedicineTypeId: String?
    @Published var isOtherMedicine = false
    @Published var otherMedicineName = ""
    @Published var doseAmount = ""
    @Published var givenAt = Date()
    @Published var notes = ""

    // MARK: - Add Type Form

    @Published var typeName = ""
    @Published var typeMinHours = 4.0
    @Published var typeMaxDoses = 4
    @Published var typeNotes = ""
    @Published var typeChildId: String?
    @Published var typeDefaultDoseAmount = ""
    @Published var typeColor = "#5B8DEF"

    // MARK: - Safety Check State

    @Published var preSubmitSafetyCheck: SafetyCheckDTO?
    @Published var isCheckingSafety = false
    @Published private(set) var safetyCheckErrorMessage: String?
    @Published private(set) var localSafetyHistoryIsComplete = true

    // MARK: - Offline Safety

    /// Bounded presentation cache. Safety checks query SwiftData independently so
    /// an old, backdated dose can never disappear behind the display limit.
    @Published var cachedDoses: [MedicineDoseDTO] = []

    func offlineSafetyWarnings(
        medicineType: MedicineTypeDTO,
        childId: String,
        givenAt candidate: Date
    ) -> [SafetyWarningDTO] {
        guard localSafetyHistoryIsComplete, let modelContext else {
            return [Self.historyUnavailableWarning]
        }

        let history: OfflineSafetyHistory
        do {
            if let offlineSafetyHistoryLoader {
                history = try offlineSafetyHistoryLoader(
                    modelContext,
                    medicineType.id,
                    childId,
                    candidate
                )
            } else {
                history = try Self.fetchOfflineSafetyHistory(
                    modelContext: modelContext,
                    medicineTypeId: medicineType.id,
                    childId: childId,
                    candidate: candidate
                )
            }
        } catch {
            Self.logger.error(
                "Unable to load complete medicine safety history: \(error.localizedDescription)"
            )
            return [Self.historyUnavailableWarning]
        }

        return Self.safetyWarnings(
            medicineType: medicineType,
            candidate: candidate,
            history: history
        )
    }

    private static func safetyWarnings(
        medicineType: MedicineTypeDTO,
        candidate: Date,
        history: OfflineSafetyHistory
    ) -> [SafetyWarningDTO] {
        let minimumInterval = medicineType.minHoursBetweenDoses * 3_600
        var warnings: [SafetyWarningDTO] = []

        if let previous = history.previousDose,
           candidate.timeIntervalSince(previous) < minimumInterval {
            let elapsed = max(0, candidate.timeIntervalSince(previous) / 3_600)
            warnings.append(
                SafetyWarningDTO(
                    type: "too_soon",
                    message: "Only \(String(format: "%.1f", elapsed))h since the previous dose. Saved minimum: \(medicineType.minHoursBetweenDoses)h.",
                    nextSafeAt: ISODateParser.stringNoFractional(
                        from: previous.addingTimeInterval(minimumInterval)
                    )
                )
            )
        }
        if let following = history.followingDose,
           following.timeIntervalSince(candidate) < minimumInterval,
           !warnings.contains(where: { $0.type == "too_soon" }) {
            let gap = following.timeIntervalSince(candidate) / 3_600
            warnings.append(
                SafetyWarningDTO(
                    type: "too_soon",
                    message: "This backdated dose is only \(String(format: "%.1f", gap))h before a later recorded dose. Saved minimum: \(medicineType.minHoursBetweenDoses)h.",
                    nextSafeAt: ISODateParser.stringNoFractional(
                        from: candidate.addingTimeInterval(minimumInterval)
                    )
                )
            )
        }

        let existingTimes = history.rollingWindowDoses.sorted()
        let windowEnds = ([candidate] + existingTimes.filter {
            $0 >= candidate && $0 <= candidate.addingTimeInterval(86_400)
        }).sorted()
        var left = 0
        var right = 0
        var highestExistingCount = 0
        for end in windowEnds {
            while right < existingTimes.count, existingTimes[right] <= end {
                right += 1
            }
            let start = end.addingTimeInterval(-86_400)
            while left < right, existingTimes[left] < start {
                left += 1
            }
            highestExistingCount = max(highestExistingCount, right - left)
        }
        // Every selected window contains the proposed dose, including the
        // candidate+24h endpoint where it lies exactly on the inclusive start.
        let highestCount = highestExistingCount + 1
        if highestCount > medicineType.maxDoses24h {
            warnings.append(
                SafetyWarningDTO(
                    type: "max_reached",
                    message: "This makes \(highestCount) doses in a rolling 24-hour window. Saved maximum: \(medicineType.maxDoses24h).",
                    nextSafeAt: nil
                )
            )
        }
        return warnings
    }

    func canLogDoseOffline(medicineType: MedicineTypeDTO, childId: String) -> (safe: Bool, reason: String?) {
        let warnings = offlineSafetyWarnings(
            medicineType: medicineType,
            childId: childId,
            givenAt: Date()
        )
        return (warnings.isEmpty, warnings.first?.message)
    }

    /// Alert state for offline safety warnings.
    @Published var showOfflineSafetyAlert = false
    @Published var offlineSafetyReason: String?

    // MARK: - Private

    private let apiClient: APIClient
    private let syncManager: SyncManager
    private let offlineSafetyHistoryLoader: OfflineSafetyHistoryLoader?
    private var modelContext: ModelContext?
    private var pendingLogDoseRequest: LogDoseRequest?
    private var pendingMedicineTypeRequest: CreateMedicineTypeRequest?
    private var safetyCheckTask: Task<SafetyCheckDTO?, Never>?
    private var safetyCheckGeneration = 0

    private struct SafetySummaryKey: Hashable {
        let medicineTypeId: String
        let childId: String
    }

    private struct SafetySummary {
        let latestDose: MedicineDoseDTO?
        let dosesInLast24Hours: Int
        let isComplete: Bool
    }

    @Published private var safetySummaries: [SafetySummaryKey: SafetySummary] = [:]

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "MedicineViewModel"
    )

    private enum DurableDoseError: LocalizedError {
        case invalidTimestamp
        case duplicateLocalDose
        case invalidMedicineType
        case duplicateLocalMedicineType

        var errorDescription: String? {
            switch self {
            case .invalidTimestamp: "The dose time is not valid."
            case .duplicateLocalDose: "That dose operation already exists locally."
            case .invalidMedicineType: "The medicine type is not valid."
            case .duplicateLocalMedicineType: "That medicine type already exists locally."
            }
        }
    }

    private static let presentationDoseLimit = 200

    private static let historyUnavailableWarning = SafetyWarningDTO(
        type: "history_unavailable",
        message: "The complete saved dose history could not be checked on this device. Review recent doses before recording.",
        nextSafeAt: nil
    )

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    init(
        apiClient: APIClient = .shared,
        syncManager: SyncManager? = nil,
        offlineSafetyHistoryLoader: OfflineSafetyHistoryLoader? = nil
    ) {
        self.apiClient = apiClient
        self.syncManager = syncManager ?? .shared
        self.offlineSafetyHistoryLoader = offlineSafetyHistoryLoader
    }

    func bindModelContext(_ context: ModelContext) {
        modelContext = context
        loadLocalMedicineData()
    }

    // MARK: - Computed Properties

    /// Medicine types filtered to the currently selected child (or all if none selected).
    var filteredMedicineTypes: [MedicineTypeDTO] {
        guard let childId = selectedChildId else {
            return medicineTypes
        }
        return medicineTypes.filter { $0.childId == childId || $0.childId == nil }
    }

    /// Recent doses filtered to the currently selected child.
    var filteredRecentDoses: [MedicineDoseDTO] {
        recentDoses.filter { dose in
            guard let givenAt = ISODateParser.parse(dose.givenAt),
                  Calendar.current.isDateInToday(givenAt) else { return false }
            return selectedChildId == nil || dose.childId == selectedChildId
        }
    }

    func doses(for type: MedicineTypeDTO) -> [MedicineDoseDTO] {
        recentDoses
            .filter { dose in
                dose.medicineTypeId == type.id
                    && (selectedChildId == nil || dose.childId == selectedChildId)
            }
            .sorted { $0.givenAt > $1.givenAt }
    }

    // MARK: - Actions

    /// Loads medicine types, recent doses, and children from the API.
    func loadData() async {
        isLoading = true
        errorMessage = nil
        loadLocalMedicineData()
        defer { isLoading = false }

        async let typesResult = fetchMedicineTypes()
        async let dosesResult = fetchRecentDoses()
        async let childrenResult = fetchChildren()

        let (types, doses, fetchedChildren) = await (typesResult, dosesResult, childrenResult)
        var localPersistenceFailed = false

        if let types {
            do {
                let pendingIDs = try pendingRecordIDs(tableName: "medicine_types")
                let pending = medicineTypes.filter { pendingIDs.contains($0.id) }
                medicineTypes = uniqueMedicineTypes(pending + types)
                try persistMedicineTypes(types)
            } catch {
                localPersistenceFailed = true
                recordLocalPersistenceFailure(error)
            }
        }
        if let doses {
            do {
                let pendingIDs = try pendingRecordIDs(tableName: "medicine_doses")
                let pending = cachedDoses.filter { pendingIDs.contains($0.id) }
                let merged = uniqueMedicineDoses(pending + doses)
                recentDoses = merged
                cachedDoses = merged
                try persistMedicineDoses(doses)
            } catch {
                localPersistenceFailed = true
                recordLocalPersistenceFailure(error)
            }
        }
        if let fetchedChildren, !fetchedChildren.isEmpty {
            children = fetchedChildren
            do {
                try persistMedicineChildren(fetchedChildren)
            } catch {
                localPersistenceFailed = true
                recordLocalPersistenceFailure(error)
            }
        }
        if doses != nil, !localPersistenceFailed {
            localSafetyHistoryIsComplete = true
        }

        // Auto-select first child if none selected
        if selectedChildId == nil, let firstChild = children.first {
            selectedChildId = firstChild.id
        }

        // Fetch active illness for selected child
        if let childId = selectedChildId {
            do {
                let illness: IllnessDTO = try await apiClient.get("/illness/active/\(childId)")
                activeIllness = illness
            } catch {
                activeIllness = nil
            }
        }

        refreshSafetySummaries()

        if (types == nil || doses == nil)
            && medicineTypes.isEmpty && recentDoses.isEmpty {
            errorMessage = "Medicine records couldn't be loaded. Try again."
        }

        isLoading = false
    }

    /// Durably records the actual-care event and its exact replay intent before
    /// starting transport. A failed or cancelled request can therefore never make
    /// a dose disappear from local safety history.
    func logDose() async {
        guard !isLoading else { return }
        if !isOtherMedicine && selectedMedicineTypeId == nil {
            errorMessage = "Please select a medicine type.".localized
            return
        }
        if isOtherMedicine && otherMedicineName.trimmingCharacters(in: .whitespaces).isEmpty {
            errorMessage = "Please enter the medicine name.".localized
            return
        }
        guard let childId = selectedChildId else {
            errorMessage = "Please select a child.".localized
            return
        }
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Sign in again before recording this dose.".localized
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let candidate = LogDoseRequest(
            id: pendingLogDoseRequest?.id ?? UUID().uuidString,
            medicineTypeId: isOtherMedicine ? nil : selectedMedicineTypeId,
            childId: childId,
            givenAt: ISODateParser.stringNoFractional(from: givenAt),
            doseAmount: doseAmount.isEmpty ? nil : doseAmount.trimmingCharacters(in: .whitespaces),
            medicineName: isOtherMedicine ? otherMedicineName.trimmingCharacters(in: .whitespaces) : nil,
            notes: notes.isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces)
        )
        let request = candidate
        pendingLogDoseRequest = request
        let candidateDate = ISODateParser.parse(request.givenAt) ?? givenAt
        let localWarnings: [SafetyWarningDTO]
        if let typeID = request.medicineTypeId {
            if let medicineType = medicineTypes.first(where: { $0.id == typeID }) {
                localWarnings = offlineSafetyWarnings(
                    medicineType: medicineType,
                    childId: request.childId,
                    givenAt: candidateDate
                )
            } else {
                localWarnings = [Self.historyUnavailableWarning]
            }
        } else {
            localWarnings = []
        }
        let optimisticDose = MedicineDoseDTO(
            id: request.id,
            medicineTypeId: request.medicineTypeId,
            childId: request.childId,
            givenAt: request.givenAt,
            givenBy: nil,
            doseAmount: request.doseAmount,
            medicineName: request.medicineName,
            notes: request.notes,
            warnings: localWarnings
        )

        do {
            try stageDoseForDirectAttempt(
                request,
                givenAt: candidateDate,
                modelContext: modelContext,
                identityLease: identityLease
            )
        } catch {
            errorMessage = "This dose was not saved, so nothing was sent. Please try again.".localized
            Self.logger.error(
                "Refused medicine transport because the durable transaction failed: \(error.localizedDescription)"
            )
            return
        }

        // The safety record is durable at this point. Presentation and Live
        // Activity state may now reflect it even if the process is cancelled.
        replaceDose(optimisticDose)
        refreshSafetySummaries()
        surfaceDoseWarnings(localWarnings)
        updateLiveActivityAfterDose(request: request)

        do {
            let result: DoseWithWarningsDTO = try await apiClient.post(
                "/medicine/doses",
                body: request
            )
            guard Self.responseDose(result.dose, exactlyMatches: request) else {
                do {
                    try syncManager.markDirectAttemptPermanent(
                        id: request.id,
                        reason: "The server acknowledged a different medicine dose payload.",
                        modelContext: modelContext,
                        expectedIdentityLease: identityLease
                    )
                } catch {
                    Self.logger.error(
                        "Could not persist medicine protocol failure: \(error.localizedDescription)"
                    )
                }
                finishDurablyRecordedDose(request: request)
                errorMessage = "The dose remains in safety history, but its server response needs review in the offline queue.".localized
                return
            }

            let warnings = Self.mergedWarnings(localWarnings, result.warnings)
            do {
                try syncManager.acknowledgeDirectAttempt(
                    id: request.id,
                    modelContext: modelContext,
                    expectedIdentityLease: identityLease
                ) {
                    try Self.upsertAcknowledgedDose(
                        result.dose,
                        in: modelContext
                    )
                }
            } catch {
                // Rollback in SyncManager restored the optimistic dose and exact
                // operation. Best-effort release is a separate throwing save; if
                // it also fails, crash recovery will release `direct_attempt`.
                do {
                    try syncManager.releaseDirectAttempt(
                        id: request.id,
                        modelContext: modelContext,
                        expectedIdentityLease: identityLease,
                        reason: "The server receipt could not be saved locally; exact replay is pending."
                    )
                } catch {
                    Self.logger.error(
                        "Medicine acknowledgement rollback remains crash-recoverable: \(error.localizedDescription)"
                    )
                }
                surfaceDoseWarnings(warnings)
                refreshSafetySummaries()
                finishDurablyRecordedDose(request: request)
                errorMessage = "Dose recorded. Its server receipt could not be saved, so the exact operation will replay safely.".localized
                return
            }

            replaceDose(Self.dose(result.dose, with: warnings))
            refreshSafetySummaries()
            surfaceDoseWarnings(warnings)
            finishDurablyRecordedDose(request: request)
        } catch {
            let resultingStatus: OfflineStatus?
            do {
                resultingStatus = try syncManager.resolveDirectAttemptFailure(
                    id: request.id,
                    error: error,
                    modelContext: modelContext,
                    expectedIdentityLease: identityLease
                )
            } catch {
                resultingStatus = nil
                Self.logger.error(
                    "Medicine failure state remains crash-recoverable: \(error.localizedDescription)"
                )
            }
            surfaceDoseWarnings(localWarnings)
            refreshSafetySummaries()
            finishDurablyRecordedDose(request: request)
            switch resultingStatus {
            case .permanent:
                errorMessage = "Dose saved in safety history, but the server rejected it. Review the offline queue for details.".localized
            case .retryable:
                errorMessage = "Dose saved on this device and will retry automatically.".localized
            case .pending:
                errorMessage = nil
            case nil, .directAttempt, .inFlight, .syncing, .synced, .failed:
                errorMessage = "Dose saved locally. Its exact replay state will recover automatically.".localized
            }
        }
    }

    /// Creates a new medicine type via the API.
    func addMedicineType() async {
        guard !typeName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Please enter a medicine name.".localized
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let candidate = CreateMedicineTypeRequest(
            id: pendingMedicineTypeRequest?.id ?? UUID().uuidString,
            name: typeName.trimmingCharacters(in: .whitespaces),
            minHoursBetweenDoses: typeMinHours,
            maxDoses24h: typeMaxDoses,
            notes: typeNotes.isEmpty ? nil : typeNotes.trimmingCharacters(in: .whitespaces),
            color: typeColor,
            defaultDoseAmount: typeDefaultDoseAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : typeDefaultDoseAmount.trimmingCharacters(in: .whitespacesAndNewlines),
            childId: typeChildId ?? selectedChildId
        )
        let request = candidate
        pendingMedicineTypeRequest = request
        guard let childId = request.childId else {
            errorMessage = "Select a child before adding a medicine type.".localized
            return
        }
        guard let modelContext,
              let identityLease = syncManager.currentIdentityLease else {
            errorMessage = "Medicine could not be saved securely on this device. Please try again.".localized
            return
        }
        let optimisticType = MedicineTypeDTO(
            id: request.id,
            name: request.name,
            minHoursBetweenDoses: request.minHoursBetweenDoses,
            maxDoses24h: request.maxDoses24h,
            notes: request.notes,
            color: request.color,
            defaultDoseAmount: request.defaultDoseAmount,
            childId: childId,
            createdAt: ISODateParser.stringNoFractional(from: Date())
        )
        let outcome = await syncManager.performDurableMutation(
            modelContext: modelContext,
            actionID: request.id,
            operation: .create,
            tableName: "medicine_types",
            recordId: request.id,
            payload: [
                "name": request.name,
                "min_hours_between_doses": request.minHoursBetweenDoses,
                "max_doses_24h": request.maxDoses24h,
                "notes": request.notes ?? NSNull(),
                "color": request.color ?? NSNull(),
                "default_dose_amount": request.defaultDoseAmount ?? NSNull(),
                "child_id": childId,
            ],
            expectedIdentityLease: identityLease
        ) {
            try Self.insertMedicineType(optimisticType, in: modelContext)
        } onStaged: { [weak self] in
            self?.replaceMedicineType(optimisticType)
            self?.refreshSafetySummaries()
            self?.showingAddType = false
            self?.resetAddTypeForm()
        } transport: { [apiClient] in
            let value: MedicineTypeDTO = try await apiClient.post(
                "/medicine/types",
                body: request
            )
            return value
        } validateAcknowledgement: { value in
            value.id == request.id ? nil : "The server acknowledged a different medicine type."
        } applyAcknowledgedResult: { value in
            try Self.upsertMedicineType(value, in: modelContext)
        }

        switch outcome {
        case .acknowledged(let value):
            replaceMedicineType(value)
            refreshSafetySummaries()
        case .queued, .transportFailed(status: .pending, error: _):
            errorMessage = nil
        case .transportFailed(status: .retryable, error: _):
            errorMessage = "Medicine was saved on this device and will retry automatically.".localized
        case .transportFailed(status: .permanent, error: _):
            errorMessage = "Medicine was saved locally, but the server rejected it. Review the offline queue.".localized
        case .acknowledgementPending:
            errorMessage = "Medicine was saved. Its server receipt will replay safely.".localized
        case .stagingFailed:
            errorMessage = "This medicine was not saved, so nothing was sent. Please try again.".localized
        case .transportFailed(status: nil, error: _),
             .transportFailed(status: .directAttempt, error: _),
             .transportFailed(status: .inFlight, error: _),
             .transportFailed(status: .syncing, error: _),
             .transportFailed(status: .synced, error: _),
             .transportFailed(status: .failed, error: _):
            errorMessage = "Medicine was saved locally. Its exact replay state will recover automatically.".localized
        }
    }

    func prepareDoseReview(for type: MedicineTypeDTO) {
        errorMessage = nil
        resetLogDoseForm()
        if let childId = type.childId {
            selectedChildId = childId
        }
        selectedMedicineTypeId = type.id
        doseAmount = type.defaultDoseAmount ?? ""
        showingLogDose = true
        if let childId = selectedChildId {
            requestSafetyCheck(typeId: type.id, childId: childId, givenAt: givenAt)
        }
    }

    func prepareOtherDoseReview() {
        errorMessage = nil
        resetLogDoseForm()
        isOtherMedicine = true
        showingLogDose = true
    }

    func prepareNewMedicineType() {
        errorMessage = nil
        editingMedicineType = nil
        resetAddTypeForm()
        typeChildId = selectedChildId
        showingAddType = true
    }

    func prepareMedicineTypeEditor(_ type: MedicineTypeDTO) {
        errorMessage = nil
        editingMedicineType = type
        typeName = type.name
        typeMinHours = type.minHoursBetweenDoses
        typeMaxDoses = type.maxDoses24h
        typeNotes = type.notes ?? ""
        typeChildId = type.childId
        typeDefaultDoseAmount = type.defaultDoseAmount ?? ""
        typeColor = type.color ?? "#5B8DEF"
        showingAddType = true
    }

    func saveMedicineType() async {
        guard let editingMedicineType else {
            await addMedicineType()
            return
        }
        let cleanName = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Please enter a medicine name.".localized
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let cleanNotes = typeNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAmount = typeDefaultDoseAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated: MedicineTypeDTO = try await apiClient.put(
                "/medicine/types/\(editingMedicineType.id)",
                body: UpdateMedicineTypeRequest(
                    name: cleanName,
                    minHoursBetweenDoses: typeMinHours,
                    maxDoses24h: typeMaxDoses,
                    notes: cleanNotes.isEmpty ? nil : cleanNotes,
                    color: typeColor,
                    defaultDoseAmount: cleanAmount.isEmpty ? nil : cleanAmount,
                    childId: typeChildId ?? selectedChildId
                )
            )
            replaceMedicineType(updated)
            try persistMedicineTypes([updated])
            showingAddType = false
            resetAddTypeForm()
            HapticManager.success()
        } catch let error as LocalPersistenceError {
            recordLocalPersistenceFailure(error)
            HapticManager.error()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            errorMessage = "Medicine changes couldn't be saved. Try again.".localized
            HapticManager.error()
        }
    }

    func archiveMedicineType(_ type: MedicineTypeDTO) async {
        errorMessage = nil
        do {
            try await apiClient.delete("/medicine/types/\(type.id)")
            try preserveArchivedMedicineName(type)
            medicineTypes.removeAll { $0.id == type.id }
            try markLocalMedicineTypeDeleted(id: type.id)
            HapticManager.success()
        } catch let error as LocalPersistenceError {
            recordLocalPersistenceFailure(error)
            HapticManager.error()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            errorMessage = "Medicine couldn't be archived. Try again.".localized
            HapticManager.error()
        }
    }

    @discardableResult
    func updateDose(
        _ dose: MedicineDoseDTO,
        givenAt: Date,
        doseAmount: String,
        medicineName: String,
        notes: String
    ) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let cleanAmount = doseAmount.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = medicineName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result: DoseWithWarningsDTO = try await apiClient.patch(
                "/medicine/doses/\(dose.id)",
                body: UpdateMedicineDoseRequest(
                    givenAt: ISODateParser.stringNoFractional(from: givenAt),
                    doseAmount: cleanAmount.isEmpty ? nil : cleanAmount,
                    clearDoseAmount: cleanAmount.isEmpty,
                    medicineName: dose.medicineTypeId == nil && !cleanName.isEmpty ? cleanName : nil,
                    notes: cleanNotes.isEmpty ? nil : cleanNotes,
                    clearNotes: cleanNotes.isEmpty
                )
            )
            replaceDose(result.dose)
            try persistMedicineDoses([result.dose])
            lastDoseWarnings = result.warnings
            showWarnings = !result.warnings.isEmpty
            editingDose = nil
            HapticManager.success()
            return true
        } catch let error as LocalPersistenceError {
            recordLocalPersistenceFailure(error)
            HapticManager.error()
            return false
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
            return false
        } catch {
            errorMessage = "Dose changes couldn't be saved. Try again.".localized
            HapticManager.error()
            return false
        }
    }

    func deleteDose(_ dose: MedicineDoseDTO) async -> Bool {
        errorMessage = nil
        do {
            try await apiClient.delete("/medicine/doses/\(dose.id)")
            recentlyDeletedDose = dose
            editingDose = nil
            recentDoses.removeAll { $0.id == dose.id }
            cachedDoses.removeAll { $0.id == dose.id }
            try markLocalDoseDeleted(id: dose.id, deleted: true)
            HapticManager.success()
            return true
        } catch let error as LocalPersistenceError {
            recordLocalPersistenceFailure(error)
            HapticManager.error()
            return false
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
            return false
        } catch {
            errorMessage = "Dose record couldn't be removed. Try again.".localized
            HapticManager.error()
            return false
        }
    }

    func undoDeleteDose() async {
        guard let dose = recentlyDeletedDose else { return }
        errorMessage = nil
        do {
            let restored: DoseWithWarningsDTO = try await apiClient.post(
                "/medicine/doses/\(dose.id)/restore"
            )
            recentlyDeletedDose = nil
            replaceDose(restored.dose)
            try persistMedicineDoses([restored.dose])
            lastDoseWarnings = restored.warnings
            showWarnings = !restored.warnings.isEmpty
            HapticManager.success()
        } catch let error as LocalPersistenceError {
            recordLocalPersistenceFailure(error)
            HapticManager.error()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            errorMessage = "Dose record couldn't be restored. Try again.".localized
            HapticManager.error()
        }
    }

    /// Starts or updates the next-safe-dose Live Activity after a dose is recorded
    /// while an illness is active for that child. Uses the medicine type's minimum
    /// interval from given_at; the illness-detail refresh corrects it with server timing.
    private func updateLiveActivityAfterDose(request: LogDoseRequest) {
        guard let illness = activeIllness, illness.childId == request.childId,
              let typeId = request.medicineTypeId,
              let type = medicineTypes.first(where: { $0.id == typeId }),
              let givenAt = ISODateParser.parse(request.givenAt) else { return }
        let childName = children.first { $0.id == request.childId }?.name ?? "Child"
        let nextSafe = givenAt.addingTimeInterval(type.minHoursBetweenDoses * 3600)
        MedicineActivityManager.shared.startOrUpdate(
            childId: request.childId,
            medicineTypeId: typeId,
            childName: childName,
            medicineName: type.name,
            nextSafeAt: nextSafe,
            isSafeNow: nextSafe <= Date(),
            lastGivenAt: givenAt
        )
    }

    /// Starts a pre-dose safety check, cancelling any superseded request. Only
    /// the latest complete input tuple may publish state.
    @discardableResult
    func requestSafetyCheck(
        typeId: String,
        childId: String,
        givenAt: Date
    ) -> Task<SafetyCheckDTO?, Never> {
        safetyCheckTask?.cancel()
        safetyCheckGeneration += 1
        let generation = safetyCheckGeneration
        isCheckingSafety = true
        preSubmitSafetyCheck = nil
        safetyCheckErrorMessage = nil

        let task = Task { [weak self] () -> SafetyCheckDTO? in
            guard let self else { return nil }
            do {
                let check: SafetyCheckDTO = try await apiClient.get(
                    "/medicine/check/\(typeId)/\(childId)",
                    queryItems: [
                        URLQueryItem(
                            name: "given_at",
                            value: ISODateParser.stringNoFractional(from: givenAt)
                        )
                    ],
                    cachePolicy: .networkOnly
                )
                guard !Task.isCancelled, safetyCheckGeneration == generation else {
                    return nil
                }
                preSubmitSafetyCheck = check
                safetyCheckErrorMessage = nil
                isCheckingSafety = false
                safetyCheckTask = nil
                return check
            } catch {
                guard safetyCheckGeneration == generation else { return nil }
                // Safety-check failure does not block logging, but must never
                // leave a result belonging to an earlier selection visible.
                preSubmitSafetyCheck = nil
                safetyCheckErrorMessage = "A current saved-limit check could not be completed. Review the recent dose history before recording."
                isCheckingSafety = false
                safetyCheckTask = nil
                return nil
            }
        }
        safetyCheckTask = task
        return task
    }

    /// Performs and awaits a latest-request-wins pre-dose safety check.
    func checkSafety(typeId: String, childId: String, givenAt: Date) async -> SafetyCheckDTO? {
        await requestSafetyCheck(typeId: typeId, childId: childId, givenAt: givenAt).value
    }

    func cancelSafetyCheck(clearResult: Bool = true) {
        safetyCheckGeneration += 1
        safetyCheckTask?.cancel()
        safetyCheckTask = nil
        isCheckingSafety = false
        if clearResult {
            preSubmitSafetyCheck = nil
            safetyCheckErrorMessage = nil
        }
    }

    // MARK: - Helpers

    /// Parses an ISO 8601 date string into a Date, trying fractional seconds first.
    func parseISO8601(_ string: String) -> Date? {
        ISODateParser.parse(string)
    }

    /// Formats an ISO 8601 date string into "HH:mm" for display.
    func formattedTime(_ isoString: String) -> String {
        guard let date = ISODateParser.parse(isoString) else { return isoString }
        return ISODateParser.timeOnly(from: date)
    }

    /// Returns a relative time description (e.g., "2h 30m ago").
    func relativeTime(_ isoString: String) -> String {
        guard let date = ISODateParser.parse(isoString) else { return "" }
        let interval = Date().timeIntervalSince(date)
        guard interval > 0 else { return "just now" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m ago"
        } else if minutes > 0 {
            return "\(minutes)m ago"
        } else {
            return "just now"
        }
    }

    /// Resolves a medicine type name from its ID, falling back to the dose's medicine_name.
    func medicineTypeName(for typeId: String?) -> String {
        guard let typeId else { return "Other" }
        return medicineTypes.first { $0.id == typeId }?.name ?? "Unknown"
    }

    /// Resolves the display name for a dose (type name or ad-hoc medicine_name).
    func doseDisplayName(_ dose: MedicineDoseDTO) -> String {
        if let name = dose.medicineName, !name.isEmpty {
            return name
        }
        return medicineTypeName(for: dose.medicineTypeId)
    }

    /// Determines the safety colour for a medicine type based on time since last dose.
    /// Green = safe to dose, Amber = approaching minimum interval, Red = too soon.
    func safetyColor(for type: MedicineTypeDTO) -> Color {
        // Find the most recent dose for this type and selected child
        guard let childId = selectedChildId else { return .green }
        let lastDose: MedicineDoseDTO?
        if modelContext != nil {
            guard let summary = safetySummary(for: type, childId: childId),
                  summary.isComplete else { return .orange }
            lastDose = summary.latestDose
        } else {
            lastDose = presentationLatestDose(for: type, childId: childId)
        }

        guard let lastDose,
              let lastDoseDate = ISODateParser.parse(lastDose.givenAt) else {
            return .green
        }

        let hoursSinceLast = Date().timeIntervalSince(lastDoseDate) / 3600.0
        let ratio = hoursSinceLast / type.minHoursBetweenDoses

        if ratio >= 1.0 {
            return .green
        } else if ratio >= 0.75 {
            return .orange
        } else {
            return .red
        }
    }

    /// Calculates the next safe dose time for a given medicine type.
    func nextSafeTime(for type: MedicineTypeDTO) -> String? {
        guard let childId = selectedChildId else { return nil }
        let lastDose = modelContext == nil
            ? presentationLatestDose(for: type, childId: childId)
            : safetySummary(for: type, childId: childId)?.latestDose

        guard let lastDose,
              let lastDoseDate = ISODateParser.parse(lastDose.givenAt) else {
            return nil
        }

        let nextSafe = lastDoseDate.addingTimeInterval(type.minHoursBetweenDoses * 3600)
        guard nextSafe > Date() else { return nil }

        return ISODateParser.timeOnly(from: nextSafe)
    }

    /// Returns the last dose info string (e.g., "Last given: 14:30 by Alex").
    func lastDoseInfo(for type: MedicineTypeDTO) -> String? {
        guard let childId = selectedChildId else { return nil }
        let lastDose = modelContext == nil
            ? presentationLatestDose(for: type, childId: childId)
            : safetySummary(for: type, childId: childId)?.latestDose

        guard let lastDose else { return nil }

        let time = formattedTime(lastDose.givenAt)
        if let givenBy = lastDose.givenBy, !givenBy.isEmpty {
            return "Last given: \(time) by \(givenBy)"
        }
        return "Last given: \(time)"
    }

    /// Counts doses of a given type in the last 24 hours for the selected child.
    func dosesIn24h(for type: MedicineTypeDTO) -> Int {
        guard let childId = selectedChildId else { return 0 }
        if let summary = safetySummary(for: type, childId: childId), summary.isComplete {
            return summary.dosesInLast24Hours
        }
        let cutoff = Date().addingTimeInterval(-24 * 3600)

        return recentDoses.filter { dose in
            guard dose.medicineTypeId != nil,
                  dose.medicineTypeId == type.id,
                  dose.childId == childId,
                  let doseDate = ISODateParser.parse(dose.givenAt) else {
                return false
            }
            return doseDate > cutoff
        }.count
    }

    func hasCompleteSafetySummary(for type: MedicineTypeDTO) -> Bool {
        guard modelContext != nil, let childId = selectedChildId else { return true }
        return safetySummary(for: type, childId: childId)?.isComplete == true
    }

    /// Resets the log dose form to default values.
    func resetLogDoseForm() {
        cancelSafetyCheck()
        selectedMedicineTypeId = nil
        isOtherMedicine = false
        otherMedicineName = ""
        doseAmount = ""
        givenAt = Date()
        notes = ""
        pendingLogDoseRequest = nil
    }

    /// Resets the add type form to default values.
    func resetAddTypeForm() {
        typeName = ""
        typeMinHours = 4.0
        typeMaxDoses = 4
        typeNotes = ""
        typeChildId = nil
        typeDefaultDoseAmount = ""
        typeColor = "#5B8DEF"
        editingMedicineType = nil
        pendingMedicineTypeRequest = nil
    }

    private func dosePayload(_ request: LogDoseRequest) -> [String: Any] {
        [
            "medicine_type_id": request.medicineTypeId.map { $0 as Any } ?? NSNull(),
            "child_id": request.childId,
            "given_at": request.givenAt,
            "dose_amount": request.doseAmount.map { $0 as Any } ?? NSNull(),
            "medicine_name": request.medicineName.map { $0 as Any } ?? NSNull(),
            "notes": request.notes.map { $0 as Any } ?? NSNull(),
        ]
    }

    private func stageDoseForDirectAttempt(
        _ request: LogDoseRequest,
        givenAt: Date,
        modelContext: ModelContext,
        identityLease: SyncManager.IdentityLease
    ) throws {
        guard ISODateParser.parse(request.givenAt) != nil else {
            throw DurableDoseError.invalidTimestamp
        }
        try syncManager.stageDurableAction(
            modelContext: modelContext,
            actionID: request.id,
            operation: .create,
            tableName: "medicine_doses",
            recordId: request.id,
            payload: dosePayload(request),
            initialStatus: .directAttempt,
            expectedIdentityLease: identityLease
        ) {
            let requestedID = request.id
            let existing = try modelContext.fetch(FetchDescriptor<MedicineDose>(
                predicate: #Predicate { $0.id == requestedID }
            ))
            guard existing.isEmpty else {
                throw DurableDoseError.duplicateLocalDose
            }
            modelContext.insert(
                MedicineDose(
                    id: request.id,
                    medicineTypeId: request.medicineTypeId ?? "",
                    childId: request.childId,
                    givenAt: givenAt,
                    givenBy: nil,
                    doseAmount: request.doseAmount,
                    medicineName: request.medicineName,
                    notes: request.notes
                )
            )
        }
    }

    private static func insertMedicineType(
        _ value: MedicineTypeDTO,
        in modelContext: ModelContext
    ) throws {
        let requestedID = value.id
        let matches = try modelContext.fetch(FetchDescriptor<MedicineType>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.isEmpty else {
            throw DurableDoseError.duplicateLocalMedicineType
        }
        try upsertMedicineType(value, in: modelContext)
    }

    private static func upsertMedicineType(
        _ value: MedicineTypeDTO,
        in modelContext: ModelContext
    ) throws {
        guard !value.id.isEmpty,
              !value.name.isEmpty,
              value.minHoursBetweenDoses >= 0,
              value.maxDoses24h > 0,
              let createdAt = ISODateParser.parse(value.createdAt) else {
            throw DurableDoseError.invalidMedicineType
        }
        let requestedID = value.id
        let matches = try modelContext.fetch(FetchDescriptor<MedicineType>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count <= 1 else {
            throw DurableDoseError.duplicateLocalMedicineType
        }
        let item: MedicineType
        if let existing = matches.first {
            item = existing
        } else {
            item = MedicineType(id: value.id)
            modelContext.insert(item)
        }
        item.name = value.name
        item.minHoursBetweenDoses = value.minHoursBetweenDoses
        item.maxDoses24h = value.maxDoses24h
        item.notes = value.notes
        item.color = value.color
        item.defaultDoseAmount = value.defaultDoseAmount
        item.childId = value.childId
        item.createdAt = createdAt
        item.updatedAt = Date()
        item.deletedAt = nil
    }

    private static func upsertAcknowledgedDose(
        _ value: MedicineDoseDTO,
        in modelContext: ModelContext
    ) throws {
        guard !value.id.isEmpty,
              !value.childId.isEmpty,
              let parsedGivenAt = ISODateParser.parse(value.givenAt) else {
            throw DurableDoseError.invalidTimestamp
        }
        let requestedID = value.id
        let matches = try modelContext.fetch(FetchDescriptor<MedicineDose>(
            predicate: #Predicate { $0.id == requestedID }
        ))
        guard matches.count <= 1 else { throw DurableDoseError.duplicateLocalDose }
        let item: MedicineDose
        if let existing = matches.first {
            item = existing
        } else {
            item = MedicineDose(
                id: value.id,
                medicineTypeId: value.medicineTypeId ?? "",
                childId: value.childId,
                givenAt: parsedGivenAt
            )
            modelContext.insert(item)
        }
        item.medicineTypeId = value.medicineTypeId ?? ""
        item.childId = value.childId
        item.givenAt = parsedGivenAt
        item.givenBy = value.givenBy
        item.doseAmount = value.doseAmount
        item.medicineName = value.medicineName
        item.notes = value.notes
        item.updatedAt = Date()
        item.deletedAt = nil
    }

    private static func responseDose(
        _ dose: MedicineDoseDTO,
        exactlyMatches request: LogDoseRequest
    ) -> Bool {
        guard dose.id == request.id,
              dose.medicineTypeId == request.medicineTypeId,
              dose.childId == request.childId,
              dose.doseAmount == request.doseAmount,
              dose.medicineName == request.medicineName,
              dose.notes == request.notes,
              let responseDate = ISODateParser.parse(dose.givenAt),
              let requestDate = ISODateParser.parse(request.givenAt) else {
            return false
        }
        return responseDate == requestDate
    }

    private static func mergedWarnings(
        _ local: [SafetyWarningDTO],
        _ server: [SafetyWarningDTO]
    ) -> [SafetyWarningDTO] {
        var seen = Set<String>()
        return (local + server).filter {
            seen.insert("\($0.type)\u{0}\($0.message)\u{0}\($0.nextSafeAt ?? "")").inserted
        }
    }

    private static func dose(
        _ dose: MedicineDoseDTO,
        with warnings: [SafetyWarningDTO]
    ) -> MedicineDoseDTO {
        MedicineDoseDTO(
            id: dose.id,
            medicineTypeId: dose.medicineTypeId,
            childId: dose.childId,
            givenAt: dose.givenAt,
            givenBy: dose.givenBy,
            doseAmount: dose.doseAmount,
            medicineName: dose.medicineName,
            notes: dose.notes,
            warnings: warnings
        )
    }

    private func surfaceDoseWarnings(_ warnings: [SafetyWarningDTO]) {
        lastDoseWarnings = warnings
        showWarnings = !warnings.isEmpty
    }

    private func finishDurablyRecordedDose(request _: LogDoseRequest) {
        showingLogDose = false
        resetLogDoseForm()
    }

    private func pendingRecordIDs(tableName: String) throws -> Set<String> {
        guard let modelContext else { return [] }
        let requestedTable=tableName
        let synced=OfflineStatus.synced
        let descriptor=FetchDescriptor<OfflineAction>(
            predicate:#Predicate { $0.tableName == requestedTable && $0.status != synced }
        )
        do {
            return Set(try modelContext.fetch(descriptor).map(\.recordId))
        } catch {
            throw LocalPersistenceError.storage(error.localizedDescription)
        }
    }

    private func recordLocalPersistenceFailure(_ error: Error) {
        modelContext?.rollback()
        localSafetyHistoryIsComplete = false
        errorMessage = "Medicine history is incomplete on this device. Review recent doses before recording more medicine and try again."
            .localized
        Self.logger.error(
            "Local medicine persistence failed closed: \(error.localizedDescription)"
        )
    }

    private func uniqueMedicineDoses(_ doses: [MedicineDoseDTO]) -> [MedicineDoseDTO] {
        var seen = Set<String>()
        return Array(doses
            .filter { seen.insert($0.id).inserted }
            .sorted(by: Self.doseComesBefore)
            .prefix(Self.presentationDoseLimit))
    }

    private func uniqueMedicineTypes(_ types: [MedicineTypeDTO]) -> [MedicineTypeDTO] {
        var seen = Set<String>()
        return types
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func replaceDose(_ dose: MedicineDoseDTO) {
        recentDoses.removeAll { $0.id == dose.id }
        recentDoses.append(dose)
        recentDoses = uniqueMedicineDoses(recentDoses)
        cachedDoses.removeAll { $0.id == dose.id }
        cachedDoses.append(dose)
        cachedDoses = uniqueMedicineDoses(cachedDoses)
    }

    private static func doseComesBefore(_ lhs: MedicineDoseDTO, _ rhs: MedicineDoseDTO) -> Bool {
        switch (ISODateParser.parse(lhs.givenAt), ISODateParser.parse(rhs.givenAt)) {
        case (let left?, let right?) where left != right:
            return left > right
        case (nil, nil) where lhs.givenAt != rhs.givenAt:
            return lhs.givenAt > rhs.givenAt
        default:
            return lhs.id > rhs.id
        }
    }

    private static func fetchOfflineSafetyHistory(
        modelContext: ModelContext,
        medicineTypeId: String,
        childId: String,
        candidate: Date
    ) throws -> OfflineSafetyHistory {
        let requestedTypeId = medicineTypeId
        let requestedChildId = childId
        let candidateTime = candidate

        var previousDescriptor = FetchDescriptor<MedicineDose>(
            predicate: #Predicate {
                $0.deletedAt == nil
                    && $0.medicineTypeId == requestedTypeId
                    && $0.childId == requestedChildId
                    && $0.givenAt <= candidateTime
            },
            sortBy: [SortDescriptor(\.givenAt, order: .reverse)]
        )
        previousDescriptor.fetchLimit = 1

        var followingDescriptor = FetchDescriptor<MedicineDose>(
            predicate: #Predicate {
                $0.deletedAt == nil
                    && $0.medicineTypeId == requestedTypeId
                    && $0.childId == requestedChildId
                    && $0.givenAt > candidateTime
            },
            sortBy: [SortDescriptor(\.givenAt, order: .forward)]
        )
        followingDescriptor.fetchLimit = 1

        let lowerBound = candidate.addingTimeInterval(-86_400)
        let upperBound = candidate.addingTimeInterval(86_400)
        let rollingDescriptor = FetchDescriptor<MedicineDose>(
            predicate: #Predicate {
                $0.deletedAt == nil
                    && $0.medicineTypeId == requestedTypeId
                    && $0.childId == requestedChildId
                    && $0.givenAt >= lowerBound
                    && $0.givenAt <= upperBound
            },
            sortBy: [SortDescriptor(\.givenAt, order: .forward)]
        )

        let previous = try modelContext.fetch(previousDescriptor).first?.givenAt
        let following = try modelContext.fetch(followingDescriptor).first?.givenAt
        let rollingWindowDoses = try modelContext.fetch(rollingDescriptor).map(\.givenAt)
        return OfflineSafetyHistory(
            previousDose: previous,
            followingDose: following,
            rollingWindowDoses: rollingWindowDoses
        )
    }

    private func safetySummary(
        for type: MedicineTypeDTO,
        childId: String
    ) -> SafetySummary? {
        safetySummaries[
            SafetySummaryKey(medicineTypeId: type.id, childId: childId)
        ]
    }

    private func presentationLatestDose(
        for type: MedicineTypeDTO,
        childId: String
    ) -> MedicineDoseDTO? {
        recentDoses
            .filter { $0.medicineTypeId == type.id && $0.childId == childId }
            .sorted(by: Self.doseComesBefore)
            .first
    }

    /// Refreshes a compact per-type/child summary from narrow predicates. Views
    /// only read this cache; SwiftData is never queried during body evaluation.
    private func refreshSafetySummaries(now: Date = Date()) {
        guard let modelContext else {
            safetySummaries = [:]
            return
        }

        var keys = Set<SafetySummaryKey>()
        let knownChildIds = Set(children.map(\.id) + [selectedChildId].compactMap { $0 })
        for type in medicineTypes {
            if let childId = type.childId {
                keys.insert(SafetySummaryKey(medicineTypeId: type.id, childId: childId))
            } else {
                for childId in knownChildIds {
                    keys.insert(SafetySummaryKey(medicineTypeId: type.id, childId: childId))
                }
            }
        }
        for dose in recentDoses {
            if let typeId = dose.medicineTypeId {
                keys.insert(SafetySummaryKey(medicineTypeId: typeId, childId: dose.childId))
            }
        }

        let cutoff = now.addingTimeInterval(-86_400)
        var refreshed: [SafetySummaryKey: SafetySummary] = [:]
        for key in keys {
            let typeId = key.medicineTypeId
            let childId = key.childId
            do {
                var latestDescriptor = FetchDescriptor<MedicineDose>(
                    predicate: #Predicate {
                        $0.deletedAt == nil
                            && $0.medicineTypeId == typeId
                            && $0.childId == childId
                    },
                    sortBy: [SortDescriptor(\.givenAt, order: .reverse)]
                )
                latestDescriptor.fetchLimit = 1
                let latest = try modelContext.fetch(latestDescriptor).first
                let countDescriptor = FetchDescriptor<MedicineDose>(
                    predicate: #Predicate {
                        $0.deletedAt == nil
                            && $0.medicineTypeId == typeId
                            && $0.childId == childId
                            && $0.givenAt >= cutoff
                            && $0.givenAt <= now
                    }
                )
                refreshed[key] = SafetySummary(
                    latestDose: latest.map(Self.doseDTO),
                    dosesInLast24Hours: try modelContext.fetchCount(countDescriptor),
                    isComplete: true
                )
            } catch {
                Self.logger.error(
                    "Unable to refresh medicine summary for \(typeId)/\(childId): \(error.localizedDescription)"
                )
                refreshed[key] = SafetySummary(
                    latestDose: nil,
                    dosesInLast24Hours: 0,
                    isComplete: false
                )
            }
        }
        safetySummaries = refreshed
    }

    private static func doseDTO(_ dose: MedicineDose) -> MedicineDoseDTO {
        MedicineDoseDTO(
            id: dose.id,
            medicineTypeId: dose.medicineTypeId.isEmpty ? nil : dose.medicineTypeId,
            childId: dose.childId,
            givenAt: ISODateParser.stringNoFractional(from: dose.givenAt),
            givenBy: dose.givenBy,
            doseAmount: dose.doseAmount,
            medicineName: dose.medicineName,
            notes: dose.notes
        )
    }

    private func replaceMedicineType(_ type: MedicineTypeDTO) {
        medicineTypes.removeAll { $0.id == type.id }
        medicineTypes.append(type)
        medicineTypes = uniqueMedicineTypes(medicineTypes)
    }

    private func preserveArchivedMedicineName(_ type: MedicineTypeDTO) throws {
        let affected = recentDoses.filter {
            $0.medicineTypeId == type.id && ($0.medicineName?.isEmpty ?? true)
        }
        let namedDoses = affected.map { dose in
            MedicineDoseDTO(
                id: dose.id,
                medicineTypeId: dose.medicineTypeId,
                childId: dose.childId,
                givenAt: dose.givenAt,
                givenBy: dose.givenBy,
                doseAmount: dose.doseAmount,
                medicineName: type.name,
                notes: dose.notes,
                warnings: dose.warnings
            )
        }
        for namedDose in namedDoses {
            replaceDose(namedDose)
        }
        try persistMedicineDoses(namedDoses)
    }

    private func loadLocalMedicineData() {
        guard let modelContext else { return }
        let storedTypes: [MedicineType]
        let storedDoses: [MedicineDose]
        let storedChildren: [Child]
        do {
            storedTypes = try modelContext.fetch(FetchDescriptor<MedicineType>(
                predicate:#Predicate { $0.deletedAt == nil }
            ))
            var doseDescriptor=FetchDescriptor<MedicineDose>(
                predicate:#Predicate { $0.deletedAt == nil },
                sortBy:[SortDescriptor(\.givenAt,order:.reverse)]
            )
            doseDescriptor.fetchLimit=200
            storedDoses = try modelContext.fetch(doseDescriptor)
            storedChildren = try modelContext.fetch(FetchDescriptor<Child>(
                predicate:#Predicate { $0.deletedAt == nil }
            ))
        } catch {
            recordLocalPersistenceFailure(
                LocalPersistenceError.storage(error.localizedDescription)
            )
            return
        }
        let localTypes = storedTypes
            .map {
                MedicineTypeDTO(
                    id: $0.id,
                    name: $0.name,
                    minHoursBetweenDoses: $0.minHoursBetweenDoses,
                    maxDoses24h: $0.maxDoses24h,
                    notes: $0.notes,
                    color: $0.color,
                    defaultDoseAmount: $0.defaultDoseAmount,
                    childId: $0.childId,
                    createdAt: ISODateParser.stringNoFractional(from: $0.createdAt)
                )
            }
        if !localTypes.isEmpty { medicineTypes = uniqueMedicineTypes(localTypes) }

        let localDoses = storedDoses
            .map {
                MedicineDoseDTO(
                    id: $0.id,
                    medicineTypeId: $0.medicineTypeId.isEmpty ? nil : $0.medicineTypeId,
                    childId: $0.childId,
                    givenAt: ISODateParser.stringNoFractional(from: $0.givenAt),
                    givenBy: $0.givenBy,
                    doseAmount: $0.doseAmount,
                    medicineName: $0.medicineName,
                    notes: $0.notes
                )
            }
        if !localDoses.isEmpty {
            cachedDoses = uniqueMedicineDoses(localDoses)
            recentDoses = cachedDoses
        }

        let localChildren = storedChildren
            .map {
                ChildDTO(
                    id: $0.id,
                    name: $0.name,
                    dateOfBirth: Self.dateOnlyFormatter.string(from: $0.dateOfBirth)
                )
            }
        if !localChildren.isEmpty { children = localChildren }
        refreshSafetySummaries()
    }

    private func persistMedicineTypes(_ values: [MedicineTypeDTO]) throws {
        guard let modelContext,!values.isEmpty else { return }
        do {
            let ids=values.map(\.id)
            let existing = try modelContext.fetch(FetchDescriptor<MedicineType>(
                predicate:#Predicate { ids.contains($0.id) }
            ))
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for value in values {
                let item = byID[value.id] ?? MedicineType(id: value.id)
                if byID[value.id] == nil {
                    modelContext.insert(item)
                    byID[value.id] = item
                }
                item.name = value.name
                item.minHoursBetweenDoses = value.minHoursBetweenDoses
                item.maxDoses24h = value.maxDoses24h
                item.notes = value.notes
                item.color = value.color
                item.defaultDoseAmount = value.defaultDoseAmount
                item.childId = value.childId
                item.createdAt = ISODateParser.parse(value.createdAt) ?? item.createdAt
                item.updatedAt = Date()
                item.deletedAt = nil
            }
            try modelContext.save()
            refreshSafetySummaries()
        } catch {
            modelContext.rollback()
            throw LocalPersistenceError.storage(error.localizedDescription)
        }
    }

    private func persistMedicineDoses(_ values: [MedicineDoseDTO]) throws {
        guard let modelContext,!values.isEmpty else { return }
        do {
            let ids=values.map(\.id)
            let existing = try modelContext.fetch(FetchDescriptor<MedicineDose>(
                predicate:#Predicate { ids.contains($0.id) }
            ))
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for value in values {
                guard !value.id.isEmpty,
                      !value.childId.isEmpty,
                      let parsedGivenAt = ISODateParser.parse(value.givenAt) else {
                    throw LocalPersistenceError.invalidRemoteDose
                }
                let item = byID[value.id] ?? MedicineDose(
                    id: value.id,
                    medicineTypeId: value.medicineTypeId ?? "",
                    childId: value.childId,
                    givenAt: parsedGivenAt
                )
                if byID[value.id] == nil {
                    modelContext.insert(item)
                    byID[value.id] = item
                }
                item.medicineTypeId = value.medicineTypeId ?? ""
                item.childId = value.childId
                item.givenAt = parsedGivenAt
                item.givenBy = value.givenBy
                item.doseAmount = value.doseAmount
                item.medicineName = value.medicineName
                item.notes = value.notes
                item.updatedAt = Date()
                item.deletedAt = nil
            }
            try modelContext.save()
            refreshSafetySummaries()
        } catch let error as LocalPersistenceError {
            modelContext.rollback()
            throw error
        } catch {
            modelContext.rollback()
            throw LocalPersistenceError.storage(error.localizedDescription)
        }
    }

    private func persistMedicineChildren(_ values: [ChildDTO]) throws {
        guard let modelContext,!values.isEmpty else { return }
        do {
            let ids=values.map(\.id)
            let existing = try modelContext.fetch(FetchDescriptor<Child>(
                predicate:#Predicate { ids.contains($0.id) }
            ))
            var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            for value in values {
                let item = byID[value.id] ?? Child(id: value.id)
                if byID[value.id] == nil {
                    modelContext.insert(item)
                    byID[value.id] = item
                }
                item.name = value.name
                item.dateOfBirth = Self.dateOnlyFormatter.date(from: value.dateOfBirth) ?? item.dateOfBirth
                item.deletedAt = nil
            }
            try modelContext.save()
            refreshSafetySummaries()
        } catch {
            modelContext.rollback()
            throw LocalPersistenceError.storage(error.localizedDescription)
        }
    }

    private func markLocalDoseDeleted(id: String, deleted: Bool) throws {
        let requestedId=id
        guard let modelContext else { throw LocalPersistenceError.missingLocalRecord }
        do {
            guard let item = try modelContext.fetch(FetchDescriptor<MedicineDose>(
                predicate:#Predicate { $0.id == requestedId }
            )).first else { throw LocalPersistenceError.missingLocalRecord }
            item.deletedAt = deleted ? Date() : nil
            item.updatedAt = Date()
            try modelContext.save()
            refreshSafetySummaries()
        } catch let error as LocalPersistenceError {
            modelContext.rollback()
            throw error
        } catch {
            modelContext.rollback()
            throw LocalPersistenceError.storage(error.localizedDescription)
        }
    }

    private func markLocalMedicineTypeDeleted(id: String) throws {
        let requestedId=id
        guard let modelContext else { throw LocalPersistenceError.missingLocalRecord }
        do {
            guard let item = try modelContext.fetch(FetchDescriptor<MedicineType>(
                predicate:#Predicate { $0.id == requestedId }
            )).first else { throw LocalPersistenceError.missingLocalRecord }
            item.deletedAt = Date()
            item.updatedAt = Date()
            try modelContext.save()
            refreshSafetySummaries()
        } catch let error as LocalPersistenceError {
            modelContext.rollback()
            throw error
        } catch {
            modelContext.rollback()
            throw LocalPersistenceError.storage(error.localizedDescription)
        }
    }

    // MARK: - Private Fetch Methods

    private func fetchMedicineTypes() async -> [MedicineTypeDTO]? {
        do {
            var queryItems: [URLQueryItem]? = nil
            if let childId = selectedChildId {
                queryItems = [URLQueryItem(name: "child_id", value: childId)]
            }
            let types: [MedicineTypeDTO] = try await apiClient.get("/medicine/types", queryItems: queryItems)
            return types.sorted { $0.name < $1.name }
        } catch {
            return nil
        }
    }

    private func fetchRecentDoses() async -> [MedicineDoseDTO]? {
        do {
            var queryItems = [URLQueryItem(name: "limit", value: "200")]
            if let childId = selectedChildId {
                queryItems.append(URLQueryItem(name: "child_id", value: childId))
            }
            let doses: [MedicineDoseDTO] = try await apiClient.get("/medicine/doses", queryItems: queryItems)
            return doses.sorted { $0.givenAt > $1.givenAt }
        } catch {
            return nil
        }
    }

    private func fetchChildren() async -> [ChildDTO]? {
        do {
            let children: [ChildDTO] = try await apiClient.get("/children/")
            return children
        } catch {
            return nil
        }
    }
}
