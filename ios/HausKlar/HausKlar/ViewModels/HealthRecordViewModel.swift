import Foundation

/// ViewModel for a child's health record: vaccinations, growth centiles and a
/// GP-ready summary. Online-only; records and reminders only.
@MainActor
final class HealthRecordViewModel: ObservableObject {

    // MARK: - Selection

    @Published var children: [ChildDTO] = []
    @Published var selectedChildId: String?

    /// True once `loadChildren()` has completed at least once, so the "no children
    /// yet" state only shows after a real fetch rather than flashing on first load.
    @Published var childrenLoaded = false

    // MARK: - Section data

    @Published var vaccinations: VaccinationsResponseDTO?
    @Published var growth: GrowthCentilesResponseDTO?
    @Published var illnesses: [IllnessDTO] = []
    @Published var summary: SummaryResponseDTO?

    /// The GP-summary lookback window start date.
    @Published var summarySince: Date = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()

    // MARK: - Status

    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    private let apiClient = APIClient.shared

    init(initialChildId: String? = nil) {
        selectedChildId = initialChildId
    }

    var selectedChildName: String {
        children.first { $0.id == selectedChildId }?.name ?? "your child"
    }

    var activeIllness: IllnessDTO? {
        illnesses.first { $0.endedAt == nil }
    }

    var completedIllnesses: [IllnessDTO] {
        illnesses.filter { $0.endedAt != nil }
    }

    var latestMeasurement: GrowthCentilePointDTO? {
        growth?.measurements.max {
            (ISODateParser.parse($0.date) ?? .distantPast)
                < (ISODateParser.parse($1.date) ?? .distantPast)
        }
    }

    var vaccinationReviewCount: Int {
        vaccinations?.vaccinations.filter { $0.status == .due || $0.status == .overdue }.count ?? 0
    }

    // MARK: - Children

    func loadChildren() async {
        do {
            let fetched: [ChildDTO] = try await apiClient.get("/children/")
            children = fetched
            if selectedChildId == nil || !fetched.contains(where: { $0.id == selectedChildId }) {
                selectedChildId = fetched.first?.id
            }
            childrenLoaded = true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load children.".localized)
        }
    }

    /// Loads one child's record as a whole. Individual failures remain visible
    /// without hiding sections that did load successfully.
    func loadRecord() async {
        guard selectedChildId != nil else { return }
        isLoading = true
        errorMessage = nil
        async let growthLoad: Void = loadGrowth(manageLoading: false)
        async let vaccinationLoad: Void = loadVaccinations(manageLoading: false)
        async let illnessLoad: Void = loadIllnesses(manageLoading: false)
        async let summaryLoad: Void = loadSummary(manageLoading: false)
        _ = await (growthLoad, vaccinationLoad, illnessLoad, summaryLoad)
        isLoading = false
    }

    /// Called when the child changes: clear cached section data and reload.
    func childChanged() async {
        vaccinations = nil
        growth = nil
        illnesses = []
        summary = nil
        await loadRecord()
    }

    // MARK: - Vaccinations

    func loadVaccinations(manageLoading: Bool = true) async {
        guard let childId = selectedChildId else { return }
        if manageLoading { isLoading = true }
        defer { if manageLoading { isLoading = false } }
        do {
            vaccinations = try await apiClient.get("/health-record/\(childId)/vaccinations")
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load vaccinations.".localized)
        }
    }

    @discardableResult
    func markVaccination(_ vaccine: VaccinationItemDTO, givenOn: Date) async -> Bool {
        guard let childId = selectedChildId else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            vaccinations = try await apiClient.post(
                "/health-record/\(childId)/vaccinations",
                body: VaccinationRecordRequest(
                    vaccineKey: vaccine.key,
                    givenOn: RenewalsViewModel.dateString(givenOn)
                )
            )
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to record the vaccination.".localized)
            HapticManager.error()
            return false
        }
    }

    @discardableResult
    func addVaccination(named name: String, givenOn: Date) async -> Bool {
        guard let childId = selectedChildId else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter the vaccine name.".localized
            return false
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            vaccinations = try await apiClient.post(
                "/health-record/\(childId)/vaccinations",
                body: AdditionalVaccinationRecordRequest(
                    vaccineName: trimmedName,
                    givenOn: RenewalsViewModel.dateString(givenOn)
                )
            )
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(
                for: error,
                fallback: "Failed to add the vaccination.".localized
            )
            HapticManager.error()
            return false
        }
    }

    @discardableResult
    func unrecordVaccination(_ vaccine: VaccinationItemDTO) async -> Bool {
        guard let childId = selectedChildId else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await apiClient.delete("/health-record/\(childId)/vaccinations/\(vaccine.key)")
            await loadVaccinations()
            HapticManager.selection()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to update the vaccination.".localized)
            HapticManager.error()
            return false
        }
    }

    // MARK: - Growth centiles

    func loadGrowth(manageLoading: Bool = true) async {
        guard let childId = selectedChildId else { return }
        if manageLoading { isLoading = true }
        defer { if manageLoading { isLoading = false } }
        do {
            growth = try await apiClient.get("/health-record/\(childId)/growth-centiles")
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load growth data.".localized)
        }
    }

    func setSex(_ sex: String) async {
        guard let childId = selectedChildId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let _: SexUpdateResponse = try await apiClient.patch(
                "/health-record/\(childId)/sex",
                body: SexUpdateRequest(sex: sex)
            )
            await loadGrowth()
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to update sex.".localized)
            HapticManager.error()
        }
    }

    @discardableResult
    func addGrowthMeasurement(
        date: Date,
        heightCm: Double?,
        weightKg: Double?,
        headCircumferenceCm: Double?,
        notes: String
    ) async -> Bool {
        guard let childId = selectedChildId else { return false }
        guard heightCm != nil || weightKg != nil else {
            errorMessage = "Enter at least a height or weight.".localized
            return false
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let _: GrowthRecordDTO = try await apiClient.post(
                "/growth/",
                body: HealthGrowthRecordRequest(
                    childId: childId,
                    date: RenewalsViewModel.dateString(date),
                    heightCm: heightCm,
                    weightKg: weightKg,
                    headCircumferenceCm: headCircumferenceCm,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes
                )
            )
            await loadGrowth()
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to add the measurement.".localized)
            HapticManager.error()
            return false
        }
    }

    // MARK: - Illness history

    func loadIllnesses(manageLoading: Bool = true) async {
        guard let childId = selectedChildId else { return }
        if manageLoading { isLoading = true }
        defer { if manageLoading { isLoading = false } }
        do {
            illnesses = try await apiClient.get(
                "/illness/",
                queryItems: [URLQueryItem(name: "child_id", value: childId)]
            )
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load illnesses.".localized)
        }
    }

    @discardableResult
    func recordIllness(
        startedOn: Date,
        endedOn: Date?,
        notes: String,
        calendar: Calendar = .current
    ) async -> Bool {
        guard let childId = selectedChildId else { return false }
        let start = calendar.startOfDay(for: startedOn)
        let end = endedOn.flatMap { Self.inclusiveEndOfDay(for: $0, calendar: calendar) }
        guard end.map({ $0 >= start }) ?? true else {
            errorMessage = "End date cannot be before start date.".localized
            return false
        }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let created: IllnessDTO = try await apiClient.post(
                "/illness/",
                body: HealthIllnessRecordRequest(
                    childId: childId,
                    startedAt: ISODateParser.stringNoFractional(from: start),
                    endedAt: end.map { ISODateParser.stringNoFractional(from: $0) },
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes
                )
            )
            illnesses.insert(created, at: 0)
            await loadSummary()
            HapticManager.success()
            return true
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to record the illness.".localized)
            HapticManager.error()
            return false
        }
    }

    func deleteIllness(_ illness: IllnessDTO) async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await apiClient.delete("/illness/\(illness.id)")
            illnesses.removeAll { $0.id == illness.id }
            await loadSummary()
            HapticManager.selection()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to delete the illness.".localized)
            HapticManager.error()
        }
    }

    static func inclusiveEndOfDay(for date: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))?
            .addingTimeInterval(-1)
    }

    // MARK: - GP summary

    func loadSummary(manageLoading: Bool = true) async {
        guard let childId = selectedChildId else { return }
        if manageLoading { isLoading = true }
        defer { if manageLoading { isLoading = false } }
        do {
            summary = try await apiClient.get(
                "/health-record/\(childId)/summary",
                queryItems: [URLQueryItem(name: "since", value: RenewalsViewModel.dateString(summarySince))]
            )
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load the GP summary.".localized)
        }
    }

    // MARK: - Helpers

    private func friendlyMessage(for error: Error, fallback: String) -> String {
        if case APIError.networkError = error {
            return "You appear to be offline. The health record needs a connection.".localized
        }
        return (error as? APIError)?.errorDescription ?? fallback
    }
}

/// Response for PATCH /health-record/{child_id}/sex.
private struct SexUpdateResponse: Decodable {
    let childId: String
    let sex: String?
}
