import Foundation
import SwiftUI
import os

// MARK: - DTOs

/// Represents a dog activity as returned by the API.
struct DogActivityDTO: Codable, Identifiable {
    let id: String
    let activityType: String
    let startedAt: String
    let endedAt: String?
    let notes: String?
    let isActive: Bool
    let doneBy: String?
    let createdAt: String
}

/// Detailed status response from the dog status endpoint.
struct DogDetailedStatusDTO: Codable {
    let walkedToday: Bool
    let fedBreakfastToday: Bool
    let fedDinnerToday: Bool
    let lastWalk: DogActivityDTO?
    let lastFeedBreakfast: DogActivityDTO?
    let lastFeedDinner: DogActivityDTO?
    let activeWalk: DogActivityDTO?
    let dogName: String
    let walkState: String
    let breakfastState: String
    let dinnerState: String
}

/// A structured vaccination record for the family dog.
struct DogVaccinationDTO: Codable, Identifiable {
    let id: String
    let vaccineName: String
    let givenOn: String
    let nextDueOn: String?
    let notes: String?
    let createdAt: String
    let updatedAt: String
}

struct DogProfileDTO: Codable {
    let id: String?
    let name: String
    let dateOfBirth: String?
    let breed: String?
    let microchipNumber: String?
    let insuranceProvider: String?
    let insurancePolicyNumber: String?
    let vetName: String?
    let vetPhone: String?
    let allergies: String?
    let medicineNotes: String?
    let breakfastWindowStart: String
    let breakfastWindowEnd: String
    let walkWindowStart: String
    let walkWindowEnd: String
    let dinnerWindowStart: String
    let dinnerWindowEnd: String

    static let empty = DogProfileDTO(
        id: nil,
        name: "Dog",
        dateOfBirth: nil,
        breed: nil,
        microchipNumber: nil,
        insuranceProvider: nil,
        insurancePolicyNumber: nil,
        vetName: nil,
        vetPhone: nil,
        allergies: nil,
        medicineNotes: nil,
        breakfastWindowStart: "07:00",
        breakfastWindowEnd: "09:00",
        walkWindowStart: "10:00",
        walkWindowEnd: "14:00",
        dinnerWindowStart: "17:00",
        dinnerWindowEnd: "19:00"
    )
}

struct DogWeightDTO: Codable, Identifiable {
    let id: String
    let measuredOn: String
    let weightKg: Double
    let notes: String?
    let createdAt: String
    let updatedAt: String
}

struct DogDocumentDTO: Codable, Identifiable {
    let id: String
    let documentId: String
    let role: String
    let title: String
    let originalFilename: String
    let mediaType: String
    let fileSize: Int
    let downloadUrl: String

    var sourceDocument: SourceDocumentDTO {
        SourceDocumentDTO(
            id: documentId,
            title: title,
            originalFilename: originalFilename,
            mediaType: mediaType,
            fileSize: fileSize,
            downloadUrl: downloadUrl
        )
    }
}

/// Request body for creating a dog activity.
private struct CreateDogActivityRequest: Encodable {
    let activityType: String
    let startedAt: String
    let endedAt: String?
    let notes: String?
    let isActive: Bool
}

private struct UpdateDogActivityRequest: Encodable {
    let activityType: String
    let startedAt: String
    let endedAt: String?
    let notes: String?
    let isActive: Bool
}

private struct FinishDogWalkRequest: Encodable {
    let endedAt: String
    let isActive = false
}

private struct CreateDogVaccinationRequest: Encodable {
    let vaccineName: String
    let givenOn: String
    let nextDueOn: String?
    let notes: String?
}

private struct UpdateDogVaccinationRequest: Encodable {
    let vaccineName: String
    let givenOn: String
    let nextDueOn: String?
    let notes: String?
}

struct DogProfileUpdateRequest: Encodable {
    let name: String
    let dateOfBirth: String?
    let breed: String?
    let microchipNumber: String?
    let insuranceProvider: String?
    let insurancePolicyNumber: String?
    let vetName: String?
    let vetPhone: String?
    let allergies: String?
    let medicineNotes: String?
    let breakfastWindowStart: String
    let breakfastWindowEnd: String
    let walkWindowStart: String
    let walkWindowEnd: String
    let dinnerWindowStart: String
    let dinnerWindowEnd: String
}

private struct CreateDogWeightRequest: Encodable {
    let measuredOn: String
    let weightKg: Double
    let notes: String?
}

private struct UpdateDogWeightRequest: Encodable {
    let measuredOn: String
    let weightKg: Double
    let notes: String?
}

private struct LinkDogDocumentRequest: Encodable {
    let documentId: String
    let role: String
}

// MARK: - ViewModel

/// ViewModel for the Dog screen. Manages dog activity loading, creation, and deletion.
@MainActor
final class DogViewModel: ObservableObject {

    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "DogViewModel"
    )

    // MARK: - Published State

    @Published var activities: [DogActivityDTO] = []
    @Published var vaccinations: [DogVaccinationDTO] = []
    @Published var profile = DogProfileDTO.empty
    @Published var weights: [DogWeightDTO] = []
    @Published var documents: [DogDocumentDTO] = []
    @Published var walkedToday = false
    @Published var fedBreakfastToday = false
    @Published var fedDinnerToday = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showingAddActivity = false
    @Published var showingAddVaccination = false
    @Published var editingActivity: DogActivityDTO?
    @Published var recentlyDeletedActivity: DogActivityDTO?
    @Published var recentlyDeletedVaccination: DogVaccinationDTO?
    @Published var recentlyDeletedWeight: DogWeightDTO?
    @Published var activeWalk: DogActivityDTO?
    @Published var walkState = "upcoming"
    @Published var breakfastState = "upcoming"
    @Published var dinnerState = "upcoming"
    @Published var showingProfileEditor = false
    @Published var showingAddWeight = false
    @Published var showingDocumentPicker = false

    // MARK: - Form Fields

    @Published var formActivityType = "walk"
    @Published var formStartedAt = Date()
    @Published var formHasEndTime = false
    @Published var formEndedAt = Date()
    @Published var formNotes = ""
    @Published var vaccinationName = ""
    @Published var vaccinationGivenOn = Date()
    @Published var vaccinationHasNextDue = false
    @Published var vaccinationNextDueOn = Date()
    @Published var vaccinationNotes = ""

    // MARK: - Constants

    let activityTypes = ["walk", "feed_breakfast", "feed_dinner", "vet", "medication"]

    // MARK: - Private

    private let apiClient = APIClient.shared
    private var familyMemberNamesById: [String: String] = [:]

    // Cached date formatters for display
    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let mediumDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .medium
        return f
    }()

    // MARK: - Duplicate Feed Detection

    /// Returns the breakfast activity logged today, if any.
    var breakfastActivityToday: DogActivityDTO? {
        activities.first { $0.activityType == "feed_breakfast" && isToday($0.startedAt) }
    }

    /// Returns the dinner activity logged today, if any.
    var dinnerActivityToday: DogActivityDTO? {
        activities.first { $0.activityType == "feed_dinner" && isToday($0.startedAt) }
    }

    /// Returns a display string for who fed and when, e.g. "Already fed by Alex at 8:30 AM".
    func alreadyFedDescription(for activity: DogActivityDTO) -> String {
        let byName = displayDoneBy(activity.doneBy) ?? "someone"
        let time = formattedTime(activity.startedAt)
        return "Already fed by \(byName) at \(time)"
    }

    private func isToday(_ isoString: String) -> Bool {
        guard let date = ISODateParser.parse(isoString) else { return false }
        return Calendar.current.isDateInToday(date)
    }

    // MARK: - Actions

    /// Loads both the dog's daily status and the activity history in parallel.
    func loadData() async {
        isLoading = true
        errorMessage = nil

        async let statusResult = fetchStatus()
        async let activitiesResult = fetchActivities()
        async let vaccinationsResult = fetchVaccinations()
        async let profileResult = fetchProfile()
        async let weightsResult = fetchWeights()
        async let documentsResult = fetchDocuments()
        async let familyMembersResult = fetchFamilyMemberNames()

        let (
            status,
            loadedActivities,
            loadedVaccinations,
            loadedProfile,
            loadedWeights,
            loadedDocuments,
            memberNamesById
        ) = await (
            statusResult,
            activitiesResult,
            vaccinationsResult,
            profileResult,
            weightsResult,
            documentsResult,
            familyMembersResult
        )

        if let status {
            walkedToday = status.walkedToday
            fedBreakfastToday = status.fedBreakfastToday
            fedDinnerToday = status.fedDinnerToday
            activeWalk = status.activeWalk
            walkState = status.walkState
            breakfastState = status.breakfastState
            dinnerState = status.dinnerState
        }
        if let memberNamesById { familyMemberNamesById = memberNamesById }
        if let loadedActivities { activities = loadedActivities }
        if let loadedVaccinations { vaccinations = loadedVaccinations }
        if let loadedProfile { profile = loadedProfile }
        if let loadedWeights { weights = loadedWeights }
        if let loadedDocuments { documents = loadedDocuments }
        if status == nil && loadedActivities == nil && activities.isEmpty {
            errorMessage = "Dog care couldn't be loaded. Try again.".localized
        }

        isLoading = false
    }

    /// Logs a new dog activity using the current form fields.
    func logActivity() async {
        let trimmedNotes = formNotes.trimmingCharacters(in: .whitespaces)

        let body = CreateDogActivityRequest(
            activityType: formActivityType,
            startedAt: ISODateParser.stringNoFractional(from: formStartedAt),
            endedAt: formHasEndTime
                ? ISODateParser.stringNoFractional(from: max(formEndedAt, formStartedAt))
                : nil,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            isActive: false
        )

        isLoading = true
        errorMessage = nil

        do {
            let created: DogActivityDTO = try await apiClient.post("/dog/activities", body: body)
            activities.insert(created, at: 0)
            showingAddActivity = false
            resetForm()
            // Reload status to reflect new walk/feed
            await loadData()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to log activity. Please try again.".localized
        }

        isLoading = false
    }

    /// Starts a shared walk timer. Ending it records the real duration.
    func logQuickWalk() async {
        if let activeWalk {
            await finishWalk(activeWalk)
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let created: DogActivityDTO = try await apiClient.post(
                "/dog/activities",
                body: CreateDogActivityRequest(
                    activityType: "walk",
                    startedAt: ISODateParser.stringNoFractional(from: Date()),
                    endedAt: nil,
                    notes: nil,
                    isActive: true
                )
            )
            replaceActivity(created)
            activeWalk = created
            await refreshStatus()
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            await refreshStatus()
        } catch {
            errorMessage = "The walk couldn't be started. Try again.".localized
        }
    }

    private func finishWalk(_ walk: DogActivityDTO) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let endedAt = Date()
            let updated: DogActivityDTO = try await apiClient.put(
                "/dog/activities/\(walk.id)",
                body: FinishDogWalkRequest(
                    endedAt: ISODateParser.stringNoFractional(from: endedAt)
                )
            )
            replaceActivity(updated)
            activeWalk = nil
            await refreshStatus()
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The walk couldn't be ended. Try again.".localized
        }
    }

    /// Quickly logs a breakfast feed with the current time and no notes.
    func logQuickBreakfast() async {
        formActivityType = "feed_breakfast"
        formStartedAt = Date()
        formHasEndTime = false
        formNotes = ""
        await logActivity()
    }

    /// Quickly logs a dinner feed with the current time and no notes.
    func logQuickDinner() async {
        formActivityType = "feed_dinner"
        formStartedAt = Date()
        formHasEndTime = false
        formNotes = ""
        await logActivity()
    }

    /// Deletes a dog activity by its ID.
    func updateActivity(
        _ activity: DogActivityDTO,
        activityType: String,
        startedAt: Date,
        endedAt: Date?,
        notes: String
    ) async -> Bool {
        guard endedAt.map({ $0 >= startedAt }) ?? true else {
            errorMessage = "End time cannot be before start time.".localized
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated: DogActivityDTO = try await apiClient.put(
                "/dog/activities/\(activity.id)",
                body: UpdateDogActivityRequest(
                    activityType: activityType,
                    startedAt: ISODateParser.stringNoFractional(from: startedAt),
                    endedAt: endedAt.map(ISODateParser.stringNoFractional),
                    notes: cleanNotes.isEmpty ? nil : cleanNotes,
                    isActive: activity.isActive && endedAt == nil && activityType == "walk"
                )
            )
            replaceActivity(updated)
            editingActivity = nil
            await refreshStatus()
            HapticManager.success()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Dog care changes couldn't be saved. Try again.".localized
        }
        HapticManager.error()
        return false
    }

    func deleteActivity(_ activity: DogActivityDTO) async {
        do {
            try await apiClient.delete("/dog/activities/\(activity.id)")
            activities.removeAll { $0.id == activity.id }
            editingActivity = nil
            recentlyDeletedActivity = activity
            await refreshStatus()
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Dog care record couldn't be removed. Try again.".localized
        }
    }

    func undoDeleteActivity() async {
        guard let activity = recentlyDeletedActivity else { return }
        do {
            let restored: DogActivityDTO = try await apiClient.post(
                "/dog/activities/\(activity.id)/restore"
            )
            replaceActivity(restored)
            recentlyDeletedActivity = nil
            await refreshStatus()
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Dog care record couldn't be restored. Try again.".localized
        }
    }

    @discardableResult
    func addVaccination() async -> Bool {
        let trimmedName = vaccinationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = vaccinationNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter the vaccine name.".localized
            return false
        }
        guard !vaccinationHasNextDue
                || Calendar.current.startOfDay(for: vaccinationNextDueOn)
                    >= Calendar.current.startOfDay(for: vaccinationGivenOn)
        else {
            errorMessage = "Next due date cannot be before the given date.".localized
            return false
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let created: DogVaccinationDTO = try await apiClient.post(
                "/dog/vaccinations",
                body: CreateDogVaccinationRequest(
                    vaccineName: trimmedName,
                    givenOn: RenewalsViewModel.dateString(vaccinationGivenOn),
                    nextDueOn: vaccinationHasNextDue
                        ? RenewalsViewModel.dateString(vaccinationNextDueOn)
                        : nil,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes
                )
            )
            vaccinations.insert(created, at: 0)
            resetVaccinationForm()
            HapticManager.success()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add the vaccination. Please try again.".localized
        }
        HapticManager.error()
        return false
    }

    func deleteVaccination(_ id: String) async {
        guard let vaccination = vaccinations.first(where: { $0.id == id }) else { return }
        do {
            try await apiClient.delete("/dog/vaccinations/\(id)")
            vaccinations.removeAll { $0.id == id }
            recentlyDeletedVaccination = vaccination
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            errorMessage = "Failed to delete the vaccination. Please try again.".localized
            HapticManager.error()
        }
    }

    func undoDeleteVaccination() async {
        guard let vaccination = recentlyDeletedVaccination else { return }
        do {
            let restored: DogVaccinationDTO = try await apiClient.post(
                "/dog/vaccinations/\(vaccination.id)/restore"
            )
            vaccinations.removeAll { $0.id == restored.id }
            vaccinations.append(restored)
            vaccinations.sort { $0.givenOn > $1.givenOn }
            recentlyDeletedVaccination = nil
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The vaccination record couldn't be restored. Try again.".localized
        }
    }

    func updateVaccination(
        _ vaccination: DogVaccinationDTO,
        name: String,
        givenOn: Date,
        nextDueOn: Date?,
        notes: String
    ) async -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Enter the vaccine name.".localized
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let updated: DogVaccinationDTO = try await apiClient.patch(
                "/dog/vaccinations/\(vaccination.id)",
                body: UpdateDogVaccinationRequest(
                    vaccineName: cleanName,
                    givenOn: RenewalsViewModel.dateString(givenOn),
                    nextDueOn: nextDueOn.map(RenewalsViewModel.dateString),
                    notes: cleanOptional(notes)
                )
            )
            vaccinations.removeAll { $0.id == updated.id }
            vaccinations.append(updated)
            vaccinations.sort { $0.givenOn > $1.givenOn }
            HapticManager.success()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The vaccination couldn't be corrected. Try again.".localized
        }
        return false
    }

    func saveProfile(_ request: DogProfileUpdateRequest) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            profile = try await apiClient.put("/dog/profile", body: request)
            await refreshStatus()
            HapticManager.success()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The pet record couldn't be saved. Try again.".localized
        }
        HapticManager.error()
        return false
    }

    func addWeight(measuredOn: Date, weightText: String, notes: String) async -> Bool {
        guard let value = Double(weightText.replacingOccurrences(of: ",", with: ".")),
              value > 0,
              value <= 200 else {
            errorMessage = "Enter a valid weight in kilograms.".localized
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let created: DogWeightDTO = try await apiClient.post(
                "/dog/weights",
                body: CreateDogWeightRequest(
                    measuredOn: RenewalsViewModel.dateString(measuredOn),
                    weightKg: value,
                    notes: cleanOptional(notes)
                )
            )
            replaceWeight(created)
            HapticManager.success()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The weight couldn't be saved. Try again.".localized
        }
        return false
    }

    func updateWeight(
        _ weight: DogWeightDTO,
        measuredOn: Date,
        weightText: String,
        notes: String
    ) async -> Bool {
        guard let value = Double(weightText.replacingOccurrences(of: ",", with: ".")),
              value > 0,
              value <= 200 else {
            errorMessage = "Enter a valid weight in kilograms.".localized
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let updated: DogWeightDTO = try await apiClient.patch(
                "/dog/weights/\(weight.id)",
                body: UpdateDogWeightRequest(
                    measuredOn: RenewalsViewModel.dateString(measuredOn),
                    weightKg: value,
                    notes: cleanOptional(notes)
                )
            )
            replaceWeight(updated)
            HapticManager.success()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The weight couldn't be corrected. Try again.".localized
        }
        return false
    }

    func deleteWeight(_ weight: DogWeightDTO) async {
        do {
            try await apiClient.delete("/dog/weights/\(weight.id)")
            weights.removeAll { $0.id == weight.id }
            recentlyDeletedWeight = weight
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The weight record couldn't be removed. Try again.".localized
        }
    }

    func undoDeleteWeight() async {
        guard let weight = recentlyDeletedWeight else { return }
        do {
            let restored: DogWeightDTO = try await apiClient.post(
                "/dog/weights/\(weight.id)/restore"
            )
            replaceWeight(restored)
            recentlyDeletedWeight = nil
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The weight record couldn't be restored. Try again.".localized
        }
    }

    func linkDocument(_ document: SourceDocumentDTO, role: String) async -> Bool {
        do {
            let linked: DogDocumentDTO = try await apiClient.post(
                "/dog/documents",
                body: LinkDogDocumentRequest(documentId: document.id, role: role)
            )
            documents.removeAll { $0.documentId == linked.documentId }
            documents.insert(linked, at: 0)
            HapticManager.success()
            return true
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The document couldn't be added to the pet record. Try again.".localized
        }
        return false
    }

    func unlinkDocument(_ document: DogDocumentDTO) async {
        do {
            try await apiClient.delete("/dog/documents/\(document.id)")
            documents.removeAll { $0.id == document.id }
            HapticManager.success()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "The document couldn't be removed from the pet record. Try again.".localized
        }
    }

    /// Resets the form fields to their defaults.
    func resetForm() {
        formActivityType = "walk"
        formStartedAt = Date()
        formHasEndTime = false
        formEndedAt = Date()
        formNotes = ""
    }

    func resetVaccinationForm() {
        vaccinationName = ""
        vaccinationGivenOn = Date()
        vaccinationHasNextDue = false
        vaccinationNextDueOn = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        vaccinationNotes = ""
    }

    // MARK: - Private Fetch Methods

    private func fetchStatus() async -> DogDetailedStatusDTO? {
        do {
            let status: DogDetailedStatusDTO = try await apiClient.get("/dog/status")
            return status
        } catch {
            Self.logger.info("Dog status section failed to load; retaining its current value.")
            return nil
        }
    }

    private func fetchActivities() async -> [DogActivityDTO]? {
        do {
            let loaded: [DogActivityDTO] = try await apiClient.get("/dog/activities")
            return loaded
        } catch {
            Self.logger.info("Dog activity section failed to load; retaining its current value.")
            return nil
        }
    }

    private func fetchVaccinations() async -> [DogVaccinationDTO]? {
        do {
            let loaded: [DogVaccinationDTO] = try await apiClient.get("/dog/vaccinations")
            return loaded
        } catch {
            Self.logger.info("Dog vaccination section failed to load; retaining its current value.")
            return nil
        }
    }

    private func fetchProfile() async -> DogProfileDTO? {
        do {
            return try await apiClient.get("/dog/profile")
        } catch {
            Self.logger.info("Dog profile section failed to load; retaining its current value.")
            return nil
        }
    }

    private func fetchWeights() async -> [DogWeightDTO]? {
        do {
            return try await apiClient.get("/dog/weights")
        } catch {
            Self.logger.info("Dog weight section failed to load; retaining its current value.")
            return nil
        }
    }

    private func fetchDocuments() async -> [DogDocumentDTO]? {
        do {
            return try await apiClient.get("/dog/documents")
        } catch {
            Self.logger.info("Dog document section failed to load; retaining its current value.")
            return nil
        }
    }

    private func fetchFamilyMemberNames() async -> [String: String]? {
        do {
            let members: [FamilyMemberDTO] = try await apiClient.get("/family/members")
            return Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) })
        } catch {
            Self.logger.info("Dog caregiver names failed to load; retaining known names.")
            return nil
        }
    }

    private func refreshStatus() async {
        guard let status = await fetchStatus() else { return }
        walkedToday = status.walkedToday
        fedBreakfastToday = status.fedBreakfastToday
        fedDinnerToday = status.fedDinnerToday
        activeWalk = status.activeWalk
        walkState = status.walkState
        breakfastState = status.breakfastState
        dinnerState = status.dinnerState
    }

    private func replaceActivity(_ activity: DogActivityDTO) {
        activities.removeAll { $0.id == activity.id }
        activities.append(activity)
        activities.sort { $0.startedAt > $1.startedAt }
    }

    private func replaceWeight(_ weight: DogWeightDTO) {
        weights.removeAll { $0.id == weight.id }
        weights.append(weight)
        weights.sort { $0.measuredOn > $1.measuredOn }
    }

    private func cleanOptional(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Helpers

    /// Returns the SF Symbol name for a given activity type.
    func iconName(for activityType: String) -> String {
        switch activityType {
        case "walk":
            return "figure.walk"
        case "feed_breakfast":
            return "sunrise.fill"
        case "feed_dinner":
            return "sunset.fill"
        case "vet":
            return "cross.case.fill"
        case "medication":
            return "pills.fill"
        default:
            return "pawprint.fill"
        }
    }

    /// Returns a display colour for a given activity type.
    func iconColor(for activityType: String) -> Color {
        switch activityType {
        case "walk":
            return .blue
        case "feed_breakfast":
            return .orange
        case "feed_dinner":
            return .orange
        case "vet":
            return .red
        case "medication":
            return .purple
        default:
            return .gray
        }
    }

    /// Returns a capitalised display label for a given activity type.
    func displayLabel(for activityType: String) -> String {
        switch activityType {
        case "walk":
            return "Walk"
        case "feed_breakfast":
            return "Breakfast"
        case "feed_dinner":
            return "Dinner"
        case "vet":
            return "Vet"
        case "medication":
            return "Medication"
        default:
            return activityType.capitalized
        }
    }

    /// Formats an ISO 8601 date string into a short time string (e.g., "10:30 AM").
    func formattedTime(_ isoString: String) -> String {
        guard let date = ISODateParser.parse(isoString) else { return isoString }
        return Self.shortTimeFormatter.string(from: date)
    }

    /// Formats an ISO 8601 date string into a relative or short date+time string.
    func formattedDateTime(_ isoString: String) -> String {
        guard let date = ISODateParser.parse(isoString) else { return isoString }
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today at \(Self.shortTimeFormatter.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday at \(Self.shortTimeFormatter.string(from: date))"
        } else {
            return Self.mediumDateTimeFormatter.string(from: date)
        }
    }

    func formattedDate(_ isoString: String) -> String {
        guard let date = ISODateParser.parse(isoString) else { return isoString }
        return ISODateParser.dateOnly(from: date)
    }

    /// Parses an ISO 8601 date string, trying fractional seconds first.
    func parseISO8601(_ string: String) -> Date? {
        ISODateParser.parse(string)
    }

    /// Returns a user-facing name for the activity author.
    /// Never surfaces raw internal IDs in the UI.
    func displayDoneBy(_ doneBy: String?) -> String? {
        guard let doneBy, !doneBy.isEmpty else { return nil }

        if let name = familyMemberNamesById[doneBy], !name.isEmpty {
            return name
        }

        if isLikelyIdentifier(doneBy) {
            return "Family member"
        }

        return doneBy
    }

    private func isLikelyIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 12 { return true }
        if trimmed.contains("-") && trimmed.count >= 8 { return true }
        if trimmed.allSatisfy({ $0.isNumber }) { return true }
        return false
    }
}
