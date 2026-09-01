import Foundation
import os
import SwiftData
import UIKit

// MARK: - ViewModel

/// ViewModel for the Settings screen. Provides display data derived from AppState.
@MainActor
final class SettingsViewModel: ObservableObject {

    private let logger = Logger(subsystem: "com.hausklar", category: "SettingsViewModel")

    // MARK: - Published State

    @Published var userName: String = ""
    @Published var userEmail: String = ""
    @Published var userRole: String = ""
    @Published var isSavingProfile = false
    @Published var profileMessage: String?
    @Published var isDeletingAccount: Bool = false
    @Published var isGeneratingInviteCode: Bool = false
    @Published var inviteCode: String?
    @Published var inviteURL: String?
    @Published var inviteExpiresAt: String?
    @Published var errorMessage: String?

    // Home Assistant settings
    @Published var haDashboardURL: String = ""
    @Published var haURL: String = ""
    @Published var haToken: String = ""
    @Published var haTokenConfigured = false
    @Published var haConnectionStatus: HAConnectionStatus = .untested
    @Published var isSavingHA: Bool = false

    @Published var calendarSources: [CalendarSourceDTO] = []
    @Published var calendarMembers: [FamilyMemberDTO] = []
    @Published var calendarSourceName = ""
    @Published var calendarSourceURL = ""
    @Published var calendarSourcePerson = ""
    @Published var calendarFeedConfigured = false
    @Published var newCalendarFeedURL: String?
    @Published var isManagingCalendars = false
    @Published var calendarError: String?
    @Published var calendarValidation: CalendarSourceValidationDTO?
    @Published var rugbySettings: SchoolRugbySettingsDTO = .unconfigured
    @Published var rugbyTeams: SchoolRugbyTeamListDTO?
    @Published var selectedRugbyTeamId = ""
    @Published var isLoadingRugby = false
    @Published var isManagingRugby = false
    @Published var rugbyError: String?
    @Published var rugbyNotice: String?
    @Published var reminderPreferences = ReminderPreferencesDTO(
        eventRemindersEnabled: true, eventMinutesBefore: 30,
        taskRemindersEnabled: true, morningSummaryEnabled: true,
        morningSummaryTime: "07:00", eveningSummaryEnabled: true,
        eveningSummaryTime: "19:00", quietStart: "21:00",
        quietEnd: "07:00", privacyMode: true
    )
    @Published var reminderPreview: [ReminderPreviewDTO] = []
    @Published var notificationsEnabled = false
    @Published var notificationPermissionDenied = false
    @Published var isSavingReminders = false
    @Published var reminderError: String?
    @Published var aiConsentStatus: AIConsentStatusDTO?
    @Published var isLoadingAIConsent = true
    @Published var isSavingAIConsent = false
    @Published var aiConsentError: String?
    @Published var usageHistorySummary: UsageHistorySummaryDTO?
    @Published var usageHistoryExportItem: ShareExportItem?
    @Published var isLoadingUsageHistory = false
    @Published var isManagingUsageHistory = false
    @Published var usageHistoryError: String?

    enum HAConnectionStatus: Equatable {
        case untested
        case testing
        case success
        case failure(String)
    }

    private let authService = AuthService()

    // MARK: - Actions

    /// Loads the current user's settings from AppState.
    func loadSettings(appState: AppState) {
        if let user = appState.currentUser {
            userName = user.name
            userEmail = user.email
            userRole = user.role
        }
    }

    func saveProfile(appState: AppState) async {
        let candidate = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate != appState.currentUser?.name else { return }
        isSavingProfile = true
        profileMessage = nil
        defer { isSavingProfile = false }
        struct Update: Encodable { let name: String }
        do {
            let updated: UserProfile = try await APIClient.shared.patch(
                "/auth/me", body: Update(name: candidate)
            )
            userName = updated.name
            appState.profileUpdated(updated)
            profileMessage = "Profile saved."
            HapticManager.success()
        } catch let error as APIError {
            profileMessage = error.errorDescription
            HapticManager.error()
        } catch {
            profileMessage = "Profile could not be saved."
            HapticManager.error()
        }
    }

    func loadAIConsent() async {
        isLoadingAIConsent = true
        aiConsentError = nil
        defer { isLoadingAIConsent = false }
        do {
            aiConsentStatus = try await APIClient.shared.get("/auth/ai-consent")
        } catch let error as APIError {
            aiConsentError = error.errorDescription
        } catch {
            aiConsentError = "AI privacy settings could not be loaded."
        }
    }

    func grantAIConsent() async {
        guard let status = aiConsentStatus, !isSavingAIConsent else { return }
        isSavingAIConsent = true
        aiConsentError = nil
        defer { isSavingAIConsent = false }
        struct ConsentRequest: Encodable {
            let accepted = true
            let version: String
        }
        do {
            aiConsentStatus = try await APIClient.shared.put(
                "/auth/ai-consent",
                body: ConsentRequest(version: status.version)
            )
            HapticManager.success()
        } catch let error as APIError {
            aiConsentError = error.errorDescription
            HapticManager.error()
        } catch {
            aiConsentError = "Permission could not be saved."
            HapticManager.error()
        }
    }

    func revokeAIConsent() async {
        guard !isSavingAIConsent else { return }
        isSavingAIConsent = true
        aiConsentError = nil
        defer { isSavingAIConsent = false }
        do {
            aiConsentStatus = try await APIClient.shared.deleteReturning("/auth/ai-consent")
            HapticManager.selection()
        } catch let error as APIError {
            aiConsentError = error.errorDescription
            HapticManager.error()
        } catch {
            aiConsentError = "Permission could not be withdrawn."
            HapticManager.error()
        }
    }

    // MARK: - Optional usage insights

    func loadUsageHistory() async {
        guard !isLoadingUsageHistory else { return }
        isLoadingUsageHistory = true
        usageHistoryError = nil
        defer { isLoadingUsageHistory = false }
        do {
            let summary: UsageHistorySummaryDTO = try await APIClient.shared.get(
                "/usage-history/summary"
            )
            usageHistorySummary = summary
            await UsageMonitor.shared.updateConsent(summary.enabled)
        } catch let error as APIError {
            usageHistoryError = error.errorDescription
        } catch {
            usageHistoryError = String(localized: "Your usage-summary choice could not be loaded.")
        }
    }

    func setUsageHistoryEnabled(_ enabled: Bool) async {
        isManagingUsageHistory = true
        usageHistoryError = nil
        defer { isManagingUsageHistory = false }
        struct Update: Encodable { let enabled: Bool }
        if !enabled {
            // Stop client collection as soon as the adult says no. If offline,
            // the queued preference change remains ahead of any later replay.
            await UsageMonitor.shared.updateConsent(false)
        }
        do {
            let preference: UsageHistoryPreferenceDTO = try await APIClient.shared.patch(
                "/usage-history/preferences", body: Update(enabled: enabled)
            )
            await UsageMonitor.shared.updateConsent(preference.enabled)
            await releaseUsageHistoryExport()
            usageHistorySummary = try await APIClient.shared.get("/usage-history/summary")
            HapticManager.selection()
        } catch let error as APIError {
            usageHistoryError = error.errorDescription
        } catch {
            usageHistoryError = String(localized: "That choice could not be saved.")
        }
    }

    func exportUsageHistory() async {
        guard !isManagingUsageHistory else { return }
        isManagingUsageHistory = true
        usageHistoryError = nil
        await releaseUsageHistoryExport()
        defer { isManagingUsageHistory = false }
        do {
            let exported: UsageHistoryExportDTO = try await APIClient.shared.get(
                "/usage-history/export"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(exported)
            try Task.checkCancellation()
            let lease = try await ShareExportStore.shared.currentLease()
            let item = try await ShareExportStore.shared.publishData(
                data,
                filename: "hausklar-recent-use-\(Self.exportDate()).json",
                lease: lease
            )
            guard !Task.isCancelled else {
                await releaseUsageHistoryItem(item, context: "cancelled export")
                return
            }
            usageHistoryExportItem = item
        } catch is CancellationError {
            return
        } catch let error as APIError {
            usageHistoryError = error.errorDescription
        } catch {
            usageHistoryError = String(localized: "Your history could not be exported.")
        }
    }

    func clearUsageHistory() async {
        isManagingUsageHistory = true
        usageHistoryError = nil
        defer { isManagingUsageHistory = false }
        do {
            let _: UsageHistoryClearDTO = try await APIClient.shared.deleteReturning(
                "/usage-history/"
            )
            await releaseUsageHistoryExport()
            usageHistorySummary = try await APIClient.shared.get("/usage-history/summary")
            HapticManager.success()
        } catch let error as APIError {
            usageHistoryError = error.errorDescription
        } catch {
            usageHistoryError = String(localized: "Your history could not be cleared.")
        }
    }

    func releaseUsageHistoryExport() async {
        guard let item = usageHistoryExportItem else { return }
        usageHistoryExportItem = nil
        await releaseUsageHistoryItem(item, context: "finished sharing")
    }

    private func releaseUsageHistoryItem(_ item: ShareExportItem, context: String) async {
        do {
            try await ShareExportStore.shared.release(item)
        } catch {
            logger.error(
                "Failed to release usage-history export after \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    nonisolated private static func exportDate() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Calendar Connections

    // MARK: - Reminders

    func loadReminders() async {
        do {
            async let preferences: ReminderPreferencesDTO = APIClient.shared.get("/reminders/preferences")
            async let preview: [ReminderPreviewDTO] = APIClient.shared.get("/reminders/preview")
            reminderPreferences = try await preferences
            reminderPreview = try await preview
            notificationsEnabled = await NotificationService.shared.authorizationStatus() == .authorized
            notificationPermissionDenied = await NotificationService.shared.authorizationStatus() == .denied
            if notificationsEnabled {
                await NotificationService.shared.scheduleReminders(preferences: reminderPreferences, items: reminderPreview)
            }
        } catch let error as APIError {
            reminderError = error.errorDescription
        } catch {
            reminderError = "Reminders could not be loaded."
        }
    }

    func enableNotifications() async {
        notificationsEnabled = await NotificationService.shared.requestPermission()
        if notificationsEnabled {
            await NotificationService.shared.scheduleReminders(preferences: reminderPreferences, items: reminderPreview)
        } else {
            notificationPermissionDenied = await NotificationService.shared.authorizationStatus() == .denied
            reminderError = "Notifications are blocked. Allow them in iOS Settings to continue."
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func saveReminders() async {
        isSavingReminders = true
        reminderError = nil
        defer { isSavingReminders = false }
        do {
            reminderPreferences = try await APIClient.shared.put("/reminders/preferences", body: reminderPreferences)
            reminderPreview = try await APIClient.shared.get("/reminders/preview")
            await NotificationService.shared.scheduleReminders(preferences: reminderPreferences, items: reminderPreview)
        } catch let error as APIError {
            reminderError = error.errorDescription
        } catch {
            reminderError = "Reminder settings could not be saved."
        }
    }

    func loadCalendarSettings() async {
        do {
            async let sourceRequest: [CalendarSourceDTO] = APIClient.shared.get("/calendar/sources")
            async let memberRequest: [FamilyMemberDTO] = APIClient.shared.get("/family/members")
            async let feedRequest: CalendarFeedStatusDTO = APIClient.shared.get("/calendar/feed")
            let (sources, members, feed) = try await (sourceRequest, memberRequest, feedRequest)
            calendarSources = sources
            calendarMembers = members
            calendarFeedConfigured = feed.configured
        } catch let error as APIError {
            calendarError = error.errorDescription
        } catch {
            calendarError = "Calendar connections could not be loaded."
        }
    }

    func loadRugbySettings() async {
        isLoadingRugby = true
        rugbyError = nil
        defer { isLoadingRugby = false }
        do {
            async let settingsRequest: SchoolRugbySettingsDTO = APIClient.shared.get(
                "/calendar/rugby"
            )
            async let teamsRequest: SchoolRugbyTeamListDTO = APIClient.shared.get(
                "/calendar/rugby/teams"
            )
            let (saved, published) = try await (settingsRequest, teamsRequest)
            rugbySettings = saved
            rugbyTeams = published
            selectedRugbyTeamId = saved.teamId ?? ""
        } catch let error as APIError {
            rugbyError = error.errorDescription
        } catch {
            rugbyError = "Example School rugby teams could not be loaded."
        }
    }

    func saveRugbyTeam() async {
        guard !selectedRugbyTeamId.isEmpty else { return }
        isManagingRugby = true
        rugbyError = nil
        rugbyNotice = nil
        defer { isManagingRugby = false }
        do {
            rugbySettings = try await APIClient.shared.put(
                "/calendar/rugby",
                body: SchoolRugbySettingsRequest(teamId: selectedRugbyTeamId)
            )
            selectedRugbyTeamId = rugbySettings.teamId ?? selectedRugbyTeamId
            rugbyNotice = rugbySettings.lastError == nil
                ? "\(rugbySettings.fixtureCount) \(rugbySettings.teamName ?? "rugby") fixture\(rugbySettings.fixtureCount == 1 ? "" : "s") added to the planner."
                : "Team saved. The fixtures need another refresh."
            HapticManager.success()
        } catch let error as APIError {
            rugbyError = error.errorDescription
            HapticManager.error()
        } catch {
            rugbyError = "The rugby team could not be saved."
            HapticManager.error()
        }
    }

    func refreshRugbyFixtures() async {
        guard rugbySettings.configured else { return }
        struct EmptyBody: Encodable {}
        isManagingRugby = true
        rugbyError = nil
        rugbyNotice = nil
        defer { isManagingRugby = false }
        do {
            let _: CalendarSourceSyncDTO = try await APIClient.shared.post(
                "/calendar/rugby/sync",
                body: EmptyBody()
            )
            rugbySettings = try await APIClient.shared.get("/calendar/rugby")
            rugbyNotice = "\(rugbySettings.fixtureCount) fixture\(rugbySettings.fixtureCount == 1 ? "" : "s") checked against Example School."
            HapticManager.success()
        } catch let error as APIError {
            rugbyError = error.errorDescription
            HapticManager.error()
        } catch {
            rugbyError = "The rugby fixtures could not be refreshed."
            HapticManager.error()
        }
    }

    func loadFamilyMembers() async {
        do {
            calendarMembers = try await APIClient.shared.get("/family/members")
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Family members could not be loaded."
        }
    }

    func addCalendarSource() async {
        guard !calendarSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !calendarSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              calendarValidation != nil else { return }
        isManagingCalendars = true
        calendarError = nil
        defer { isManagingCalendars = false }
        do {
            let source: CalendarSourceDTO = try await APIClient.shared.post(
                "/calendar/sources",
                body: CreateCalendarSourceRequest(
                    name: calendarSourceName,
                    url: calendarSourceURL,
                    assignedTo: calendarSourcePerson.isEmpty ? nil : calendarSourcePerson,
                    color: "#2563EB"
                )
            )
            calendarSources.removeAll { $0.id == source.id }
            calendarSources.append(source)
            calendarSources.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            calendarSourceName = ""
            calendarSourceURL = ""
            calendarSourcePerson = ""
            calendarValidation = nil
        } catch let error as APIError {
            calendarError = error.errorDescription
        } catch {
            calendarError = "Calendar could not be added."
        }
    }

    func calendarCandidateChanged() {
        calendarValidation = nil
        calendarError = nil
    }

    func validateCalendarSource() async {
        guard !calendarSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !calendarSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isManagingCalendars = true
        calendarError = nil
        defer { isManagingCalendars = false }
        do {
            calendarValidation = try await APIClient.shared.post(
                "/calendar/sources/validate",
                body: CreateCalendarSourceRequest(
                    name: calendarSourceName,
                    url: calendarSourceURL,
                    assignedTo: calendarSourcePerson.isEmpty ? nil : calendarSourcePerson,
                    color: "#2563EB"
                )
            )
            HapticManager.success()
        } catch let error as APIError {
            calendarError = error.errorDescription
            HapticManager.error()
        } catch {
            calendarError = "Calendar link could not be checked."
            HapticManager.error()
        }
    }

    func syncCalendarSource(_ source: CalendarSourceDTO) async {
        isManagingCalendars = true
        calendarError = nil
        defer { isManagingCalendars = false }
        struct EmptyBody: Encodable {}
        do {
            let _: CalendarSourceSyncDTO = try await APIClient.shared.post(
                "/calendar/sources/\(source.id)/sync", body: EmptyBody()
            )
            calendarSources = try await APIClient.shared.get("/calendar/sources")
        } catch let error as APIError {
            calendarError = error.errorDescription
        } catch {
            calendarError = "Calendar could not be refreshed."
        }
    }

    func deleteCalendarSource(_ source: CalendarSourceDTO) async {
        isManagingCalendars = true
        defer { isManagingCalendars = false }
        do {
            try await APIClient.shared.delete("/calendar/sources/\(source.id)")
            calendarSources.removeAll { $0.id == source.id }
        } catch let error as APIError {
            calendarError = error.errorDescription
        } catch {
            calendarError = "Calendar could not be removed."
        }
    }

    func rotateCalendarFeed() async {
        isManagingCalendars = true
        calendarError = nil
        defer { isManagingCalendars = false }
        struct EmptyBody: Encodable {}
        do {
            let feed: CalendarFeedCreatedDTO = try await APIClient.shared.post(
                "/calendar/feed/rotate", body: EmptyBody()
            )
            calendarFeedConfigured = true
            newCalendarFeedURL = feed.feedUrl
        } catch let error as APIError {
            calendarError = error.errorDescription
        } catch {
            calendarError = "Subscription link could not be created."
        }
    }

    // MARK: - HA Settings

    /// Loads HA settings from the backend.
    func loadHASettings() async {
        KeychainManager.deleteLegacyHomeAssistantCredentials()
        do {
            let settings: HASettingsResponse = try await APIClient.shared.get("/family/settings/ha")
            haDashboardURL = settings.dashboardUrl ?? ""
            haURL = settings.haUrl ?? ""
            haToken = ""
            haTokenConfigured = settings.tokenConfigured
        } catch {
            logger.error("Failed to load HA settings: \(error.localizedDescription)")
        }
    }

    func haCandidateChanged() {
        haConnectionStatus = .untested
        errorMessage = nil
    }

    /// Saves HA settings to the backend. Admin only.
    func saveHASettings() async {
        guard haConnectionStatus == .success else { return }
        isSavingHA = true
        errorMessage = nil
        defer {
            isSavingHA = false
            haToken = ""
        }

        struct HASettingsUpdate: Codable {
            let dashboardUrl: String?
            let haUrl: String?
            let haToken: String?
        }

        let body = HASettingsUpdate(
            dashboardUrl: haDashboardURL.isEmpty ? nil : haDashboardURL,
            haUrl: haURL.isEmpty ? nil : haURL,
            haToken: haToken.isEmpty ? nil : haToken
        )

        do {
            let response: HASettingsResponse = try await APIClient.shared.put("/family/settings/ha", body: body)
            haTokenConfigured = response.tokenConfigured
            haConnectionStatus = .untested
            KeychainManager.deleteLegacyHomeAssistantCredentials()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to save HA settings.".localized
        }
    }

    /// Tests candidate credentials without storing them first.
    func testHAConnection() async {
        haConnectionStatus = .testing

        struct TestResponse: Codable {
            let success: Bool
            let message: String
        }

        struct Candidate: Codable {
            let haUrl: String?
            let haToken: String?
        }

        do {
            let response: TestResponse = try await APIClient.shared.post(
                "/family/settings/ha/test",
                body: Candidate(
                    haUrl: haURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : haURL,
                    haToken: haToken.isEmpty ? nil : haToken
                )
            )
            if response.success {
                haConnectionStatus = .success
            } else {
                haConnectionStatus = .failure(response.message)
            }
        } catch let error as APIError {
            haConnectionStatus = .failure(error.errorDescription ?? "Connection failed")
        } catch {
            haConnectionStatus = .failure(error.localizedDescription)
        }
    }

    func deleteAccount(appState: AppState, modelContext: ModelContext) async {
        isDeletingAccount = true
        errorMessage = nil
        defer { isDeletingAccount = false }
        do {
            let fitnessIdentity = FitnessDatabase.shared.activeIdentity
            try await authService.deleteMyAccount()
            await FitnessHealthKitService.shared.suspend()
            await FitnessRecoveryService.shared.suspend()
            await FitnessNutritionService.shared.suspend()
            await FitnessActivityService.shared.suspend()
            await FitnessSyncService.shared.suspend()
            try FitnessDatabase.shared.deleteActiveStore()
            if let fitnessIdentity {
                try FitnessPendingFITInbox.purgeOwned(identity: fitnessIdentity)
            }
            await appState.logout()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to delete account. Please try again.".localized
        }
    }

    static func purgeLocalData(_ modelContext: ModelContext) throws {
        DocumentCaptureService.purgePendingUploads()
        try LocalIdentityDataPurger.purgeRecords(modelContext)
    }

    func generateInviteCode() async {
        isGeneratingInviteCode = true
        errorMessage = nil
        defer { isGeneratingInviteCode = false }
        do {
            let invitation = try await authService.generateInviteCode()
            inviteCode = invitation.inviteCode
            inviteURL = invitation.joinUrl
            inviteExpiresAt = invitation.expiresAt
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to generate invite code. Please try again.".localized
        }
    }
}

struct UsageHistoryPreferenceDTO: Codable {
    let enabled: Bool
    let retentionDays: Int
}

struct UsageModuleSummaryDTO: Codable, Identifiable {
    let module: String
    let actions: Int
    let activeDays: Int
    var id: String { module }
}

struct UsageScreenSummaryDTO: Codable, Identifiable {
    let module: String
    let surface: String
    let views: Int
    let activeDays: Int
    var id: String { "\(module):\(surface)" }
}

struct UsageControlSummaryDTO: Codable, Identifiable {
    let module: String
    let action: String
    let surface: String
    let presses: Int
    let activeDays: Int
    var id: String { "\(module):\(action):\(surface)" }
}

struct UsageWorkflowSummaryDTO: Codable, Identifiable {
    let module: String
    let workflow: String
    let action: String
    let starts: Int
    let completions: Int
    let failures: Int
    let abandonments: Int
    let queuedCompletions: Int
    let averageInteractions: Double?
    var id: String { "\(module):\(workflow):\(action)" }
}

struct UsageHistorySummaryDTO: Codable {
    var enabled: Bool
    let periodDays: Int
    let meaningfulActions: Int
    let failedActions: Int
    let activeDays: Int
    let useSignal: String
    let repeatModules: [UsageModuleSummaryDTO]
    let bothAdultsContributed: Bool
    let sharedFamilyActions: Int
    let screenViews: [UsageScreenSummaryDTO]
    let controlUses: [UsageControlSummaryDTO]
    let workflows: [UsageWorkflowSummaryDTO]
    let lastActionAt: String?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        periodDays = try values.decode(Int.self, forKey: .periodDays)
        meaningfulActions = try values.decode(Int.self, forKey: .meaningfulActions)
        failedActions = try values.decode(Int.self, forKey: .failedActions)
        activeDays = try values.decode(Int.self, forKey: .activeDays)
        useSignal = try values.decode(String.self, forKey: .useSignal)
        repeatModules = try values.decode([UsageModuleSummaryDTO].self, forKey: .repeatModules)
        bothAdultsContributed = try values.decode(Bool.self, forKey: .bothAdultsContributed)
        sharedFamilyActions = try values.decode(Int.self, forKey: .sharedFamilyActions)
        screenViews = try values.decodeIfPresent(
            [UsageScreenSummaryDTO].self, forKey: .screenViews
        ) ?? []
        controlUses = try values.decodeIfPresent(
            [UsageControlSummaryDTO].self, forKey: .controlUses
        ) ?? []
        workflows = try values.decodeIfPresent(
            [UsageWorkflowSummaryDTO].self, forKey: .workflows
        ) ?? []
        lastActionAt = try values.decodeIfPresent(String.self, forKey: .lastActionAt)
    }
}

struct UsageHistoryEventExportDTO: Codable {
    let module: String
    let action: String
    let outcome: String
    let entrySource: String
    let effort: String
    let appVersion: String
    let eventKind: String?
    let surface: String?
    let workflow: String?
    let workflowRunId: String?
    let durationBucket: String?
    let interactionCount: Int?
    let connectivity: String?
    let failureClass: String?
    let recordedAt: String
}

struct UsageHistoryExportDTO: Codable {
    let generatedAt: String
    let retentionDays: Int
    let events: [UsageHistoryEventExportDTO]
}

struct UsageHistoryClearDTO: Codable {
    let cleared: Int
}

enum OnboardingModuleDTO: String, Codable, CaseIterable, Identifiable {
    case children
    case medicineSleep = "medicine_sleep"
    case dog
    case home
    case fitness
    case finance

    var id: String { rawValue }

    /// Only offer choices here when finishing onboarding changes the native
    /// product immediately. The other family areas are available in context
    /// and must not masquerade as configurable modules.
    static let nativeSetupChoices: [OnboardingModuleDTO] = [.fitness]

    var title: String {
        switch self {
        case .children: String(localized: "Children")
        case .medicineSleep: String(localized: "Medicine & sleep")
        case .dog: String(localized: "Dog")
        case .home: String(localized: "House")
        case .fitness: String(localized: "Fitness")
        case .finance: String(localized: "Finance")
        }
    }

    var detail: String {
        switch self {
        case .children: String(localized: "Naps, medicine, artwork, stars and school life")
        case .medicineSleep: String(localized: "Fast safety records when family life is intense")
        case .dog: String(localized: "Walks, feeding and care")
        case .home: String(localized: "Household controls and calm exceptions")
        case .fitness: String(localized: "Plans, activities, recovery, nutrition and body records in one place.")
        case .finance: String(localized: "Private adult money and shared commitments")
        }
    }
}

enum FirstFamilyOnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case firstCommitment
    case people
    case preferences

    var id: Int { rawValue }
}

enum OnboardingReminderChoice: String, CaseIterable, Identifiable {
    case commitments
    case tasks
    case morningSummary
    case eveningSummary

    var id: String { rawValue }
}

enum FirstCommitmentDuration: Int, CaseIterable, Identifiable {
    case thirtyMinutes = 30
    case oneHour = 60
    case ninetyMinutes = 90
    case twoHours = 120

    static let defaultDuration: FirstCommitmentDuration = .thirtyMinutes

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .thirtyMinutes: String(localized: "30 minutes")
        case .oneHour: String(localized: "1 hour")
        case .ninetyMinutes: String(localized: "1 hour 30 minutes")
        case .twoHours: String(localized: "2 hours")
        }
    }
}

struct OnboardingStatusDTO: Codable, Equatable, Identifiable {
    let familyName: String
    let peopleCount: Int
    let adultCount: Int
    let childCount: Int
    let calendarCommitmentCount: Int
    let remindersConfigured: Bool
    let selectedModules: [OnboardingModuleDTO]
    let dismissed: Bool
    let completed: Bool
    let shouldShow: Bool
    let firstSuccess: Bool

    var id: String { familyName }
}

private struct OnboardingUpdateRequest: Encodable {
    let selectedModules: [OnboardingModuleDTO]?
    let dismissed: Bool?
    let completed: Bool?
}

private struct OnboardingChildRequest: Encodable {
    let id: String
    let name: String
    let dateOfBirth: String
}

private struct OnboardingIDResponse: Decodable {
    let id: String
}

@MainActor
final class FirstFamilyOnboardingViewModel: ObservableObject {
    @Published var status: OnboardingStatusDTO
    @Published var step: FirstFamilyOnboardingStep = .welcome
    @Published var inviteCode: String?
    @Published var inviteURL: String?
    @Published var childName = ""
    @Published var childDateOfBirth = Date()
    @Published var eventTitle = ""
    @Published var eventDate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @Published var eventDuration = FirstCommitmentDuration.defaultDuration
    @Published var reminderPreferences = ReminderPreferencesDTO(
        eventRemindersEnabled: true, eventMinutesBefore: 30,
        taskRemindersEnabled: true, morningSummaryEnabled: true,
        morningSummaryTime: "07:00", eveningSummaryEnabled: true,
        eveningSummaryTime: "19:00", quietStart: "21:00",
        quietEnd: "07:00", privacyMode: true
    )
    @Published var enableDeviceNotifications = false
    @Published var selectedModules: Set<OnboardingModuleDTO>
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var completionStatus: OnboardingStatusDTO?
    @Published var notificationPermissionDenied = false

    private let authService = AuthService()

    init(status: OnboardingStatusDTO) {
        self.status = status
        selectedModules = Set(status.selectedModules)
        childDateOfBirth = Calendar.current.date(byAdding: .year, value: -6, to: Date()) ?? Date()
    }

    func loadReminderChoices() async {
        guard step == .preferences else { return }
        do {
            let preferences: ReminderPreferencesDTO = try await APIClient.shared.get(
                "/reminders/preferences"
            )
            reminderPreferences = preferences
        } catch is CancellationError {
            return
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = String(localized: "Reminder choices could not be loaded.")
        }
    }

    func dismiss() async -> OnboardingStatusDTO? {
        await updateStatus(dismissed: true, completed: nil)
    }

    func generateInvite() async {
        await perform {
            let invite = try await authService.generateInviteCode()
            inviteCode = invite.inviteCode
            inviteURL = invite.joinUrl
        }
    }

    func addChild() async {
        let name = childName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = String(localized: "Enter the child’s name.")
            return
        }
        await perform {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let _: OnboardingIDResponse = try await APIClient.shared.post(
                "/children/",
                body: OnboardingChildRequest(
                    id: UUID().uuidString.lowercased(),
                    name: name,
                    dateOfBirth: formatter.string(from: childDateOfBirth)
                )
            )
            childName = ""
            status = try await APIClient.shared.get("/auth/onboarding")
        }
    }

    func addFirstCommitment() async {
        let title = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = String(localized: "Say what’s happening.")
            return
        }
        await perform {
            let formatter = ISO8601DateFormatter()
            let request = CreateCalendarEventRequest(
                id: UUID().uuidString.lowercased(),
                title: title,
                description: nil,
                startTime: formatter.string(from: eventDate),
                endTime: formatter.string(
                    from: eventDate.addingTimeInterval(TimeInterval(eventDuration.rawValue * 60))
                ),
                allDay: false,
                recurrenceRule: nil,
                location: nil,
                familyMemberIds: nil,
                affectedMemberIds: nil,
                assignedTo: nil
            )
            let _: CalendarEventDTO = try await APIClient.shared.post("/calendar/", body: request)
            status = try await APIClient.shared.get("/auth/onboarding")
            eventTitle = ""
            HapticManager.success()
        }
    }

    func finish(appState: AppState) async -> OnboardingStatusDTO? {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let saved: ReminderPreferencesDTO = try await APIClient.shared.put(
                "/reminders/preferences", body: reminderPreferences
            )
            reminderPreferences = saved

            if enableDeviceNotifications {
                let allowed = await NotificationService.shared.requestPermission()
                notificationPermissionDenied = !allowed
                if allowed {
                    let preview: [ReminderPreviewDTO] = try await APIClient.shared.get("/reminders/preview")
                    await NotificationService.shared.scheduleReminders(preferences: saved, items: preview)
                }
            }

            if selectedModules.contains(.fitness) {
                guard await appState.updateFitnessWorkspace(enabled: true, pinned: true) else {
                    errorMessage = appState.fitnessWorkspaceErrorMessage ?? String(localized: "Fitness could not be enabled. Try again when you are connected.")
                    return nil
                }
            }

            let completed: OnboardingStatusDTO = try await APIClient.shared.patch(
                "/auth/onboarding",
                body: OnboardingUpdateRequest(
                    selectedModules: selectedModules.sorted { $0.rawValue < $1.rawValue },
                    dismissed: nil,
                    completed: true
                )
            )
            status = completed
            completionStatus = completed
            HapticManager.success()
            return completed
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = String(localized: "Setup choices could not be saved.")
        }
        return nil
    }

    func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func updateStatus(dismissed: Bool?, completed: Bool?) async -> OnboardingStatusDTO? {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let updated: OnboardingStatusDTO = try await APIClient.shared.patch(
                "/auth/onboarding",
                body: OnboardingUpdateRequest(
                    selectedModules: selectedModules.sorted { $0.rawValue < $1.rawValue },
                    dismissed: dismissed,
                    completed: completed
                )
            )
            status = updated
            return updated
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = String(localized: "Setup could not be updated.")
        }
        return nil
    }

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch let error as APIError {
            errorMessage = error.errorDescription
            HapticManager.error()
        } catch {
            errorMessage = String(localized: "That could not be completed. Try again.")
            HapticManager.error()
        }
    }
}
