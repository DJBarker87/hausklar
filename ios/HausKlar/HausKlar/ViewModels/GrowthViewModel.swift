import Foundation

// MARK: - DTOs

/// Growth record data transfer object as returned by the API.
struct GrowthRecordDTO: Codable, Identifiable {
    let id: String
    let childId: String
    let date: String
    let heightCm: Double?
    let weightKg: Double?
    let headCircumferenceCm: Double?
    let notes: String?
}

private struct GrowthChartDTO: Codable {
    let records: [GrowthRecordDTO]
    let childName: String
    let childDob: String
}

/// A lightweight child DTO for the child selector in growth tracking.
struct GrowthChildDTO: Codable, Identifiable {
    let id: String
    let name: String
}

/// Request body for adding a new growth record.
private struct AddGrowthRecordBody: Encodable {
    let childId: String
    let date: String
    let heightCm: Double?
    let weightKg: Double?
    let headCircumferenceCm: Double?
    let notes: String?
}

// MARK: - ViewModel

/// ViewModel for the Growth screen. Manages growth record loading, display, and creation.
@MainActor
final class GrowthViewModel: ObservableObject {

    // MARK: - Published State

    @Published var records: [GrowthRecordDTO] = []
    @Published var children: [GrowthChildDTO] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showingAddRecord = false
    @Published var selectedChildId: String?
    @Published var selectedRecordForEdit: GrowthRecordDTO?
    @Published var recordPendingDelete: GrowthRecordDTO?

    // MARK: - Form Fields

    @Published var formDate = Date()
    @Published var formHeightCm = ""
    @Published var formWeightKg = ""
    @Published var formHeadCircumference = ""
    @Published var formNotes = ""
    @Published var editDate = Date()
    @Published var editHeightCm = ""
    @Published var editWeightKg = ""
    @Published var editHeadCircumference = ""
    @Published var editNotes = ""

    // MARK: - Private

    private let apiClient = APIClient.shared

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Actions

    /// Loads children for the selector and growth records for the selected child.
    func loadChildren() async {
        do {
            let fetched: [GrowthChildDTO] = try await apiClient.get("/children/")
            children = fetched
            if selectedChildId == nil, let first = fetched.first {
                selectedChildId = first.id
            }
        } catch {
            if errorMessage == nil {
                errorMessage = "Failed to load children.".localized
            }
        }
    }

    /// Loads growth records for the currently selected child from the API.
    func loadRecords() async {
        guard let childId = selectedChildId, !childId.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let fetched: GrowthChartDTO = try await apiClient.get("/growth/chart/\(childId)")
            records = fetched.records.sorted { $0.date < $1.date }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load growth records.".localized
        }

        isLoading = false
    }

    /// Adds a new growth record using the current form values.
    func addRecord() async {
        guard let childId = selectedChildId, !childId.isEmpty else {
            errorMessage = "Please select a child.".localized
            return
        }

        let height = Double(formHeightCm.trimmingCharacters(in: .whitespaces))
        let weight = Double(formWeightKg.trimmingCharacters(in: .whitespaces))
        let headCirc = Double(formHeadCircumference.trimmingCharacters(in: .whitespaces))

        guard height != nil || weight != nil else {
            errorMessage = "Please enter at least a height or weight.".localized
            return
        }

        isLoading = true
        errorMessage = nil

        let dateString = Self.dateOnlyFormatter.string(from: formDate)
        let trimmedNotes = formNotes.trimmingCharacters(in: .whitespaces)

        let body = AddGrowthRecordBody(
            childId: childId,
            date: dateString,
            heightCm: height,
            weightKg: weight,
            headCircumferenceCm: headCirc,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )

        do {
            let _: GrowthRecordDTO = try await apiClient.post("/growth/", body: body)
            showingAddRecord = false
            resetForm()
            await loadRecords()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to add growth record. Please try again.".localized
        }

        isLoading = false
    }

    /// Resets the add-record form fields to their defaults.
    func resetForm() {
        formDate = Date()
        formHeightCm = ""
        formWeightKg = ""
        formHeadCircumference = ""
        formNotes = ""
    }

    func startEditing(_ record: GrowthRecordDTO) {
        selectedRecordForEdit = record
        editDate = Self.dateOnlyFormatter.date(from: record.date) ?? Date()
        editHeightCm = record.heightCm.map { String($0) } ?? ""
        editWeightKg = record.weightKg.map { String($0) } ?? ""
        editHeadCircumference = record.headCircumferenceCm.map { String($0) } ?? ""
        editNotes = record.notes ?? ""
    }

    func saveEditedRecord() async {
        guard let record = selectedRecordForEdit else { return }
        let height = Double(editHeightCm.trimmingCharacters(in: .whitespaces))
        let weight = Double(editWeightKg.trimmingCharacters(in: .whitespaces))
        let headCirc = Double(editHeadCircumference.trimmingCharacters(in: .whitespaces))
        guard height != nil || weight != nil else {
            errorMessage = "Please enter at least a height or weight.".localized
            return
        }

        let body = AddGrowthRecordBody(
            childId: record.childId,
            date: Self.dateOnlyFormatter.string(from: editDate),
            heightCm: height,
            weightKg: weight,
            headCircumferenceCm: headCirc,
            notes: editNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : editNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        do {
            let _: GrowthRecordDTO = try await apiClient.put("/growth/\(record.id)", body: body)
            selectedRecordForEdit = nil
            await loadRecords()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to update growth record.".localized
        }
    }

    func deleteRecord(_ record: GrowthRecordDTO) async {
        do {
            try await apiClient.delete("/growth/\(record.id)")
            if recordPendingDelete?.id == record.id {
                recordPendingDelete = nil
            }
            await loadRecords()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to delete growth record.".localized
        }
    }

    /// Returns the name of the currently selected child, or nil.
    func selectedChildName() -> String? {
        children.first { $0.id == selectedChildId }?.name
    }

    /// Returns the most recent record for display at the top.
    var latestRecord: GrowthRecordDTO? {
        records.last
    }
}
