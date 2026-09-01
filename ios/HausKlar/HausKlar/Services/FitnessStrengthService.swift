import Foundation
import os
import UserNotifications

private let fitnessStrengthServiceLogger = Logger(
    subsystem:"org.example.hausklar",
    category:"FitnessStrengthService"
)

actor FitnessStrengthService {
    static let shared = FitnessStrengthService()

    private let repository: FitnessRepository
    private let apiClient: APIClient
    private let notifications: UNUserNotificationCenter

    init(
        repository: FitnessRepository = .shared,
        apiClient: APIClient = .shared,
        notifications: UNUserNotificationCenter = .current()
    ) {
        self.repository=repository
        self.apiClient=apiClient
        self.notifications=notifications
    }

    func startRestTimer(sessionId: String,seconds: Int) async throws {
        guard (1...7_200).contains(seconds) else { throw FitnessRepositoryError.invalidStrengthEntry }
        let ownerIdentity = APIClient.shared.cacheIdentity
        let deadline=Date().addingTimeInterval(TimeInterval(seconds))
        try await repository.setRestTimer(sessionId: sessionId,deadline: deadline)
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationId(sessionId)])
        let settings=await notifications.notificationSettings()
        guard ownerIdentity != nil,
              APIClient.shared.cacheIdentity == ownerIdentity,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }
        let content=UNMutableNotificationContent()
        let display = NotificationPrivacyPolicy.displayContent(
            kind: .fitness,
            title: "Rest complete",
            body: "Your next set is ready.",
            privacyMode: NotificationPrivacyPolicyStore.shared.privacyMode(for: ownerIdentity)
        )
        content.title=display.title
        content.body=display.body
        content.sound = .default
        let request=UNNotificationRequest(
            identifier: notificationId(sessionId),content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds),repeats: false)
        )
        try await notifications.add(request)
    }

    func clearRestTimer(sessionId: String) async throws {
        try await repository.setRestTimer(sessionId: sessionId,deadline: nil)
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationId(sessionId)])
    }

    func suggestions() async throws -> [FitnessStrengthSuggestion] {
        let response: FitnessStrengthSuggestionsResponse = try await apiClient.get(
            "/fitness/strength/suggestions",bypassCache: true
        )
        return response.suggestions
    }

    func bodyLocations() async -> [FitnessBodyLocation] {
        do {
            let values: [FitnessBodyLocation] = try await apiClient.get("/fitness/body-locations")
            return values.filter(\.active).isEmpty ? FitnessBodyLocation.fallback : values.filter(\.active)
        } catch {
            return FitnessBodyLocation.fallback
        }
    }

    func previewExerciseMerge(sourceId: String,targetId: String) async throws -> FitnessExerciseMergePreview {
        try await apiClient.post(
            "/fitness/exercises/merge/preview",
            body: FitnessStrengthMergeRequest(sourceId: sourceId,targetId: targetId)
        )
    }

    func mergeExercises(sourceId: String,targetId: String) async throws -> FitnessExerciseMergePreview {
        let result: FitnessExerciseMergePreview = try await apiClient.post(
            "/fitness/exercises/merge",
            body: FitnessStrengthMergeRequest(sourceId: sourceId,targetId: targetId)
        )
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            fitnessStrengthServiceLogger.error(
                "Immediate Fitness sync after exercise merge was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        return result
    }

    func previewSetupMerge(sourceId: String,targetId: String) async throws -> FitnessExerciseSetupMergePreview {
        try await apiClient.post(
            "/fitness/exercise-setups/merge/preview",
            body: FitnessStrengthMergeRequest(sourceId: sourceId,targetId: targetId)
        )
    }

    func mergeSetups(sourceId: String,targetId: String) async throws -> FitnessExerciseSetupMergePreview {
        let result: FitnessExerciseSetupMergePreview = try await apiClient.post(
            "/fitness/exercise-setups/merge",
            body: FitnessStrengthMergeRequest(sourceId: sourceId,targetId: targetId)
        )
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            fitnessStrengthServiceLogger.error(
                "Immediate Fitness sync after setup merge was deferred: \(error.localizedDescription, privacy: .public)"
            )
        }
        return result
    }

    private func notificationId(_ sessionId: String) -> String { "FITNESS-REST-\(sessionId)" }
}
