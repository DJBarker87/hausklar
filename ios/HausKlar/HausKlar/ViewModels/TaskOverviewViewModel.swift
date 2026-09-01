import Foundation
import SwiftUI

/// DTO for a person's task overview from the API.
struct TaskOverviewPersonDTO: Codable, Identifiable {
    let personId: String
    let personName: String
    let personType: String
    let totalPending: Int
    let totalCompletedToday: Int
    let overdue: Int

    var id: String { personId }
}

/// ViewModel for the task overview screen showing per-person task summaries.
@MainActor
final class TaskOverviewViewModel: ObservableObject {

    @Published var people: [TaskOverviewPersonDTO] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadOverview() async {
        isLoading = true
        errorMessage = nil

        do {
            let result: [TaskOverviewPersonDTO] = try await APIClient.shared.get("/tasks/overview")
            people = result
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load overview. Please try again.".localized
        }

        isLoading = false
    }
}
