import Foundation
import SwiftUI

// MARK: - Illness DTOs

struct IllnessDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let startedAt: String
    let endedAt: String?
    let notes: String?
    let createdAt: String
    let updatedAt: String
}

struct TemperatureReadingDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let illnessId: String?
    let valueCelsius: Double
    let recordedAt: String
    let notes: String?
    let createdAt: String
}

struct NextDoseTimeDTO: Codable, Identifiable {
    var id: String { medicineTypeId }
    let medicineTypeId: String
    let medicineName: String
    let nextSafeAt: String?
    let isSafeNow: Bool
    let defaultDoseAmount: String?
    let color: String?
    let lastGivenAt: String?
}

struct IllnessDetailDTO: Codable {
    let illness: IllnessDTO
    let temperatureReadings: [TemperatureReadingDTO]
    let medicineDoses: [IllnessDoseDTO]
    let nextDoseTimes: [NextDoseTimeDTO]
}

struct IllnessDoseDTO: Codable, Identifiable {
    let id: String
    let medicineTypeId: String?
    let childId: String
    let givenAt: String
    let doseAmount: String?
    let notes: String?
    let medicineNameDisplay: String?
    let color: String?
}

// MARK: - Request bodies

private struct StartIllnessRequest: Encodable {
    let childId: String
    let startedAt: String
    let notes: String?
}

private struct EndIllnessRequest: Encodable {
    let endedAt: String
}

/// Encoding `nil` explicitly is significant: it is the API operation that
/// reopens a completed episode. A synthesised optional would omit the key.
private struct ReopenIllnessRequest: Encodable {
    enum CodingKeys: String, CodingKey { case endedAt = "ended_at" }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .endedAt)
    }
}

private struct CorrectIllnessRequest: Encodable {
    let startedAt: String
    let endedAt: String?
    let notes: String
}

private struct LogTemperatureRequest: Encodable {
    let childId: String
    let illnessId: String?
    let valueCelsius: Double
    let recordedAt: String
    let notes: String?
}

private struct CorrectTemperatureRequest: Encodable {
    let valueCelsius: Double
    let recordedAt: String
    let notes: String?
}

// MARK: - IllnessViewModel

/// Owns one coherent illness episode. When `illnessId` is supplied this model
/// stays pinned to that historical episode; otherwise it follows the selected
/// child's current episode.
@MainActor
final class IllnessViewModel: ObservableObject {
    @Published var activeIllness: IllnessDTO?
    @Published var illnessDetail: IllnessDetailDTO?
    @Published var temperatureReadings: [TemperatureReadingDTO] = []
    @Published var children: [ChildDTO] = []
    @Published var selectedChildId: String?
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    // Start episode
    @Published var showingStartIllness = false
    @Published var illnessStartedAt = Date()
    @Published var illnessNotes = ""

    // Temperature add/correction
    @Published var showingTemperatureEditor = false
    @Published var editingTemperatureId: String?
    @Published var temperatureValue: Double = 37.0
    @Published var temperatureDate = Date()
    @Published var temperatureNotes = ""

    // Episode correction
    @Published var showingEpisodeEditor = false
    @Published var correctedStartedAt = Date()
    @Published var correctedEndedAt = Date()
    @Published var correctedNotes = ""

    private let apiClient = APIClient.shared
    private let requestedIllnessId: String?

    init(initialChildId: String? = nil, illnessId: String? = nil) {
        selectedChildId = initialChildId
        requestedIllnessId = illnessId
    }

    var episode: IllnessDTO? { illnessDetail?.illness ?? activeIllness }
    var isActiveEpisode: Bool { episode?.endedAt == nil }
    var canSelectChild: Bool { requestedIllnessId == nil }

    var selectedChildName: String {
        children.first { $0.id == (episode?.childId ?? selectedChildId) }?.name ?? "Child"
    }

    // MARK: - Loading

    func loadData() async {
        isLoading = true
        errorMessage = nil

        do {
            let fetchedChildren: [ChildDTO] = try await apiClient.get("/children/")
            children = fetchedChildren
            if selectedChildId == nil || !fetchedChildren.contains(where: { $0.id == selectedChildId }) {
                selectedChildId = fetchedChildren.first?.id
            }
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load children.".localized)
        }

        if let requestedIllnessId {
            await loadIllnessDetail(illnessId: requestedIllnessId, manageLoading: false)
        } else if let childId = selectedChildId {
            await loadActiveIllness(childId: childId, manageLoading: false)
        } else {
            activeIllness = nil
            illnessDetail = nil
            temperatureReadings = []
        }

        isLoading = false
    }

    func childChanged(to childId: String) async {
        guard canSelectChild else { return }
        selectedChildId = childId
        activeIllness = nil
        illnessDetail = nil
        temperatureReadings = []
        await loadActiveIllness(childId: childId)
    }

    func loadActiveIllness(childId: String, manageLoading: Bool = true) async {
        if manageLoading { isLoading = true }
        defer { if manageLoading { isLoading = false } }
        errorMessage = nil
        do {
            let illness: IllnessDTO = try await apiClient.get("/illness/active/\(childId)")
            activeIllness = illness
            await loadIllnessDetail(illnessId: illness.id, manageLoading: false)
        } catch APIError.notFound {
            activeIllness = nil
            illnessDetail = nil
            temperatureReadings = []
        } catch {
            activeIllness = nil
            illnessDetail = nil
            temperatureReadings = []
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load the illness episode.".localized)
        }
    }

    func loadIllnessDetail(illnessId: String, manageLoading: Bool = true) async {
        if manageLoading { isLoading = true }
        defer { if manageLoading { isLoading = false } }
        do {
            let detail: IllnessDetailDTO = try await apiClient.get("/illness/\(illnessId)/detail")
            illnessDetail = detail
            temperatureReadings = detail.temperatureReadings
            selectedChildId = detail.illness.childId
            activeIllness = detail.illness.endedAt == nil ? detail.illness : nil
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to load the illness episode.".localized)
        }
    }

    // MARK: - Episode lifecycle

    func startIllness() async {
        guard let childId = selectedChildId else {
            errorMessage = "Please select a child.".localized
            return
        }
        guard illnessStartedAt <= Date() else {
            errorMessage = "The illness start cannot be in the future.".localized
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let trimmedNotes = illnessNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = StartIllnessRequest(
            childId: childId,
            startedAt: ISODateParser.stringNoFractional(from: illnessStartedAt),
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )

        do {
            let illness: IllnessDTO = try await apiClient.post("/illness/", body: request)
            activeIllness = illness
            showingStartIllness = false
            illnessNotes = ""
            illnessStartedAt = Date()
            await loadIllnessDetail(illnessId: illness.id)
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to start illness tracking.".localized)
            HapticManager.error()
        }
    }

    func endIllness(at date: Date = Date()) async {
        guard let illness = episode, illness.endedAt == nil else { return }
        guard date >= (parseISO8601(illness.startedAt) ?? .distantPast), date <= Date() else {
            errorMessage = "Recovery time must be after the illness began and not in the future.".localized
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let _: IllnessDTO = try await apiClient.put(
                "/illness/\(illness.id)",
                body: EndIllnessRequest(endedAt: ISODateParser.stringNoFractional(from: date))
            )
            MedicineActivityManager.shared.end(childName: selectedChildName)
            await loadIllnessDetail(illnessId: illness.id)
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to end the illness episode.".localized)
            HapticManager.error()
        }
    }

    func reopenIllness() async {
        guard let illness = episode, illness.endedAt != nil else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let _: IllnessDTO = try await apiClient.put(
                "/illness/\(illness.id)",
                body: ReopenIllnessRequest()
            )
            await loadIllnessDetail(illnessId: illness.id)
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to reopen the illness episode.".localized)
            HapticManager.error()
        }
    }

    func prepareEpisodeCorrection() {
        guard let illness = episode else { return }
        correctedStartedAt = parseISO8601(illness.startedAt) ?? Date()
        correctedEndedAt = illness.endedAt.flatMap(parseISO8601) ?? Date()
        correctedNotes = illness.notes ?? ""
        errorMessage = nil
        showingEpisodeEditor = true
    }

    func saveEpisodeCorrection() async {
        guard let illness = episode else { return }
        let endedAt = illness.endedAt == nil ? nil : correctedEndedAt
        guard correctedStartedAt <= Date(), endedAt.map({ $0 <= Date() }) ?? true else {
            errorMessage = "Illness dates cannot be in the future.".localized
            return
        }
        guard endedAt.map({ $0 >= correctedStartedAt }) ?? true else {
            errorMessage = "Recovery time cannot be before the illness began.".localized
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let _: IllnessDTO = try await apiClient.put(
                "/illness/\(illness.id)",
                body: CorrectIllnessRequest(
                    startedAt: ISODateParser.stringNoFractional(from: correctedStartedAt),
                    endedAt: endedAt.map(ISODateParser.stringNoFractional),
                    notes: correctedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            showingEpisodeEditor = false
            await loadIllnessDetail(illnessId: illness.id)
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to correct the illness episode.".localized)
            HapticManager.error()
        }
    }

    // MARK: - Temperatures

    func prepareTemperatureEditor(for reading: TemperatureReadingDTO? = nil) {
        editingTemperatureId = reading?.id
        temperatureValue = reading?.valueCelsius ?? 37.0
        temperatureDate = reading.flatMap { parseISO8601($0.recordedAt) } ?? Date()
        temperatureNotes = reading?.notes ?? ""
        errorMessage = nil
        showingTemperatureEditor = true
    }

    func saveTemperature() async {
        guard let illness = episode else { return }
        guard (30.0...45.0).contains(temperatureValue), temperatureDate <= Date() else {
            errorMessage = "Enter a temperature between 30.0 and 45.0°C at a time that has already happened.".localized
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let notes = temperatureNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let readingId = editingTemperatureId {
                let _: TemperatureReadingDTO = try await apiClient.put(
                    "/illness/temperature/\(readingId)",
                    body: CorrectTemperatureRequest(
                        valueCelsius: temperatureValue,
                        recordedAt: ISODateParser.stringNoFractional(from: temperatureDate),
                        notes: notes.isEmpty ? nil : notes
                    )
                )
            } else {
                let _: TemperatureReadingDTO = try await apiClient.post(
                    "/illness/temperature",
                    body: LogTemperatureRequest(
                        childId: illness.childId,
                        illnessId: illness.id,
                        valueCelsius: temperatureValue,
                        recordedAt: ISODateParser.stringNoFractional(from: temperatureDate),
                        notes: notes.isEmpty ? nil : notes
                    )
                )
            }
            showingTemperatureEditor = false
            resetTemperatureForm()
            await loadIllnessDetail(illnessId: illness.id)
            HapticManager.success()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to save the temperature.".localized)
            HapticManager.error()
        }
    }

    func deleteTemperature(_ reading: TemperatureReadingDTO) async {
        guard let illness = episode else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await apiClient.delete("/illness/temperature/\(reading.id)")
            await loadIllnessDetail(illnessId: illness.id)
            HapticManager.selection()
        } catch {
            errorMessage = friendlyMessage(for: error, fallback: "Failed to remove the temperature.".localized)
            HapticManager.error()
        }
    }

    func resetTemperatureForm() {
        editingTemperatureId = nil
        temperatureValue = 37.0
        temperatureDate = Date()
        temperatureNotes = ""
    }

    // MARK: - Display helpers

    func parseISO8601(_ string: String) -> Date? { ISODateParser.parse(string) }

    func formattedTime(_ isoString: String) -> String {
        guard let date = ISODateParser.parse(isoString) else { return isoString }
        return ISODateParser.timeOnly(from: date)
    }

    func formattedDateTime(_ isoString: String) -> String {
        guard let date = ISODateParser.parse(isoString) else { return isoString }
        return ISODateParser.dateTime(from: date)
    }

    func episodeDuration(_ illness: IllnessDTO, now: Date = Date()) -> String {
        guard let start = parseISO8601(illness.startedAt) else { return "" }
        let end = illness.endedAt.flatMap(parseISO8601) ?? now
        let components = Calendar.current.dateComponents([.day, .hour], from: start, to: end)
        let days = max(0, components.day ?? 0)
        let hours = max(0, components.hour ?? 0)
        if days > 0 { return days == 1 ? "1 day, \(hours) hr" : "\(days) days, \(hours) hrs" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    private func friendlyMessage(for error: Error, fallback: String) -> String {
        if case APIError.networkError = error {
            return "You appear to be offline. Illness changes need a connection.".localized
        }
        return (error as? APIError)?.errorDescription ?? fallback
    }
}
