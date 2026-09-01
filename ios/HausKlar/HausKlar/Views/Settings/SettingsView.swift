import SwiftUI
import SwiftData
import UIKit
import CoreImage.CIFilterBuiltins
import os

private let settingsLogoutLogger = Logger(
    subsystem: "org.example.hausklar",
    category: "SettingsLogout"
)

/// The app settings screen. Displays account info, caregiver handover setup,
/// app information, and logout functionality.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = SettingsViewModel()
    @Query private var offlineActions: [OfflineAction]
    @Query private var pendingDocumentUploads: [PendingDocumentUpload]
    @EnvironmentObject private var languageManager: LanguageManager
    @State private var showingDeleteAccountAlert = false
    @State private var showingChangePassword = false
    @State private var calendarSourcePendingDeletion: CalendarSourceDTO?
    @State private var showingReplaceFeedAlert = false
    @State private var showingLogoutDiscardAlert = false
    @State private var pendingFitnessItemCount = 0
    @State private var pendingHTTPMutationCount = 0
    @State private var isCheckingLogout = false
    @State private var showingLogoutSafetyError = false
    @State private var logoutSafetyErrorMessage = ""
    @State private var logoutSyncWarning: String?
    @State private var reminderAutoSaveReady = false
    @State private var reminderSaveTask: Task<Void, Never>?
    @State private var pendingPrivacyMode: Bool?
    @State private var showingUsageHistoryConsent = false
    @State private var showingClearUsageHistory = false

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { accountSettingsDetail } label: {
                    categoryRow("Account", icon: "person.example_35fbacff.circle", status: viewModel.userName, next: "Edit profile and understand access")
                }
                NavigationLink { notificationSettingsDetail } label: {
                    categoryRow("Notifications", icon: "bell.badge", status: "Checked when opened", next: "Choose useful reminders")
                }
                NavigationLink { TabBarCustomizationView() } label: {
                    categoryRow(
                        "Navigation",
                        icon: "rectangle.3.group",
                        status: "Today, Calendar and Family stay put",
                        next: "Choose your other two tabs"
                    )
                }
                NavigationLink { personalWorkspacesDetail } label: {
                    categoryRow("Personal workspaces", icon: "person.example_35fbacff.square", status: "Private to your account", next: "Money and optional Fitness")
                }
                NavigationLink { familySettingsDetail } label: {
                    categoryRow("Family & sharing", icon: "person.example_f47e224f", status: isAdmin ? "You can manage people" : "Shared household", next: isAdmin ? "Invite or review people" : "See roles and handover")
                }
                NavigationLink { connectionSettingsDetail } label: {
                    categoryRow("Connections", icon: "link", status: isAdmin ? "Checked when opened" : "Administrator managed", next: "Calendars and home systems")
                }
                NavigationLink { privacySettingsDetail } label: {
                    categoryRow("Privacy & AI", icon: "hand.raised", status: "Explicit choices only", next: "Review data processing")
                }
                NavigationLink { advancedSettingsDetail } label: {
                    categoryRow("Security & data", icon: "lock.example_9ab66176", status: "Your account and data", next: "Password, language and deletion")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .alert("Delete Account?", isPresented: $showingDeleteAccountAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        await viewModel.deleteAccount(appState: appState, modelContext: modelContext)
                    }
                }
            } message: {
                Text("This permanently deletes your account, private settings and identity links, then logs you out. Shared household records remain anonymously for other members. The final account also deletes every live family record and file. Isolated encrypted backups follow the retention policy in Privacy.")
            }
            .task {
                viewModel.loadSettings(appState: appState)
                do {
                    try await refreshPendingLogoutWork()
                } catch {
                    settingsLogoutLogger.error(
                        "Background logout-safety count failed: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
            .sheet(isPresented: $showingChangePassword) {
                ChangePasswordView(isRequired: false)
            }
            .alert("Remove Calendar?", isPresented: Binding(
                get: { calendarSourcePendingDeletion != nil },
                set: { if !$0 { calendarSourcePendingDeletion = nil } }
            )) {
                Button("Cancel", role: .cancel) { calendarSourcePendingDeletion = nil }
                Button("Remove", role: .destructive) {
                    guard let source = calendarSourcePendingDeletion else { return }
                    calendarSourcePendingDeletion = nil
                    Task { await viewModel.deleteCalendarSource(source) }
                }
            } message: {
                Text("Its imported events will be removed from HausKlar.")
            }
            .alert("Replace Subscription Link?", isPresented: $showingReplaceFeedAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Replace") { Task { await viewModel.rotateCalendarFeed() } }
            } message: {
                Text("The existing link will stop working immediately.")
            }
            .alert("Discard unsynced work and log out?", isPresented: $showingLogoutDiscardAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Try Syncing") {
                    Task { await syncPendingLogoutWork() }
                }
                Button("Discard & Log Out", role: .destructive) {
                    Task { await appState.logoutAndRevoke() }
                }
            } message: {
                if let logoutSyncWarning {
                    Text("\(logoutSyncWarning) This device still has \(unsyncedItemCount) item\(unsyncedItemCount == 1 ? "" : "s") waiting to upload. Logging out will permanently remove it from this device.")
                } else {
                    Text("This device still has \(unsyncedItemCount) item\(unsyncedItemCount == 1 ? "" : "s") waiting to upload, including any pending Fitness work. Logging out will permanently remove it from this device.")
                }
            }
            .alert("Local work could not be checked", isPresented: $showingLogoutSafetyError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(logoutSafetyErrorMessage)
            }
            .alert(
                pendingPrivacyMode == true ? "Hide family details on the lock screen?" : "Show family details on the lock screen?",
                isPresented: Binding(
                    get: { pendingPrivacyMode != nil },
                    set: { if !$0 { pendingPrivacyMode = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { pendingPrivacyMode = nil }
                Button(pendingPrivacyMode == true ? "Use Private Wording" : "Show Details") {
                    if let value = pendingPrivacyMode {
                        viewModel.reminderPreferences.privacyMode = value
                    }
                    pendingPrivacyMode = nil
                }
            } message: {
                Text(pendingPrivacyMode == true
                     ? "Notifications will use neutral wording until HausKlar opens."
                     : "Event and task names may be visible to anyone who can see this device’s lock screen.")
            }
            .alert("Allow private usage summary?", isPresented: $showingUsageHistoryConsent) {
                Button("Not Now", role: .cancel) {}
                Button("Allow") {
                    Task { await viewModel.setUsageHistoryEnabled(true) }
                }
            } message: {
                Text("With your permission, your HausKlar server will keep reviewed screen and button IDs, generic workflow stages linked by a random per-attempt ID, coarse duration and tap count, connectivity, iOS or web source, app version and timestamp for 28 days. These facts are linked to your account for your private summary and used only to evaluate which features help. Names, notes, searches, food and booking details, assistant messages, health values, document details, request bodies and response bodies are never recorded. There is no advertising or cross-app tracking. You can turn this off and clear the active summary at any time.")
            }
            .alert("Clear your recent HausKlar history?", isPresented: $showingClearUsageHistory) {
                Button("Cancel", role: .cancel) {}
                Button("Clear my history", role: .destructive) {
                    Task { await viewModel.clearUsageHistory() }
                }
            } message: {
                Text("This removes only your short usage summary. It does not delete family records, Finance or Fitness data.")
            }
        }
    }

    private func categoryRow(_ title: String, icon: String, status: String, next: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(status).font(.caption).foregroundStyle(.secondary)
                Text(next).font(.caption2).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
    }

    private var accountSettingsDetail: some View {
        List {
            accountSection
        }
        .navigationTitle("Account")
        .task { viewModel.loadSettings(appState: appState) }
    }

    private var personalWorkspacesDetail: some View {
        List {
            if appState.currentUser?.familyId != nil { moneySection }
            fitnessWorkspaceSection
        }
        .navigationTitle("Personal workspaces")
    }

    private var notificationSettingsDetail: some View {
        List { remindersSection }
            .navigationTitle("Notifications")
            .task {
                reminderAutoSaveReady = false
                await viewModel.loadReminders()
                reminderAutoSaveReady = true
            }
            .onChange(of: viewModel.reminderPreferences) { _, preferences in
                guard reminderAutoSaveReady else { return }
                reminderSaveTask?.cancel()
                reminderSaveTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(450))
                    } catch {
                        return
                    }
                    guard viewModel.reminderPreferences == preferences else { return }
                    await viewModel.saveReminders()
                }
            }
            .onDisappear {
                reminderSaveTask?.cancel()
                reminderSaveTask = nil
            }
    }

    private var familySettingsDetail: some View {
        List {
            roleAndVisibilitySection
            if isAdmin { familyInviteSection }
            babysitterSection
        }
        .navigationTitle("Family & sharing")
        .task { await viewModel.loadFamilyMembers() }
    }

    private var connectionSettingsDetail: some View {
        List {
            if isAdmin {
                rugbyConnectionsSection
                calendarConnectionsSection
                homeAssistantSection
            } else {
                Section {
                    ContentUnavailableView(
                        "Administrator managed",
                        systemImage: "lock.example_9ab66176",
                        description: Text("A family administrator can connect calendars and home systems. You can use connected services without seeing private links or tokens.")
                    )
                }
            }
        }
        .navigationTitle("Connections")
        .task {
            guard isAdmin else { return }
            async let home: Void = viewModel.loadHASettings()
            async let calendars: Void = viewModel.loadCalendarSettings()
            async let rugby: Void = viewModel.loadRugbySettings()
            _ = await (home, calendars, rugby)
        }
    }

    private var privacySettingsDetail: some View {
        List {
            aiPrivacySection
            legalSection
        }
        .navigationTitle("Privacy & AI")
        .task { await viewModel.loadAIConsent() }
    }

    private var advancedSettingsDetail: some View {
        List {
            usageHistorySection
            securitySection
            languageSection
            appInfoSection
            logoutSection
            dangerZoneSection
            disclaimerSection
        }
        .navigationTitle("Security & data")
        .task { await viewModel.loadUsageHistory() }
        .onDisappear {
            Task { await viewModel.releaseUsageHistoryExport() }
        }
    }

    private var usageHistorySection: some View {
        Section("Optional usage insights") {
            if viewModel.isLoadingUsageHistory && viewModel.usageHistorySummary == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading your usage-summary choice…")
                        .foregroundStyle(.secondary)
                }
            } else if let summary = viewModel.usageHistorySummary {
                Toggle("Keep a private 28-day usage summary", isOn: Binding(
                    get: { summary.enabled },
                    set: { enabled in
                        if enabled {
                            showingUsageHistoryConsent = true
                        } else {
                            Task { await viewModel.setUsageHistoryEnabled(false) }
                        }
                    }
                ))
                .disabled(viewModel.isManagingUsageHistory)

                if summary.enabled {
                    Label(
                        "Enabled with your permission · stored on your HausKlar server",
                        systemImage: "checkmark.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(usageActionSummary(summary))
                            .fontWeight(.semibold)

                        if summary.useSignal == "returning" {
                            Text("HausKlar has helped on more than one day.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if summary.useSignal == "started" {
                            Text("Your first useful action is in this summary.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if summary.repeatModules.isEmpty {
                            Text("Repeat use will appear here after an area helps on more than one day.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(usageRepeatSummary(summary.repeatModules))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if summary.bothAdultsContributed {
                            Label("Both adults completed shared family actions in this period.", systemImage: "person.example_f47e224f.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if summary.failedActions > 0 {
                            Text(usageFailureSummary(summary.failedActions))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !summary.screenViews.isEmpty {
                            Text(usageScreenSummary(summary.screenViews))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !summary.controlUses.isEmpty {
                            Text(usageControlSummary(summary.controlUses))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !summary.workflows.isEmpty {
                            ForEach(summary.workflows.prefix(5)) { workflow in
                                Text(usageWorkflowSummary(workflow))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Text("For 28 days, the server remembers only reviewed screen and button IDs, generic workflow stages linked by a random per-attempt ID, coarse duration and tap count, connectivity, iOS or web, app version and timestamp. It never stores names, notes, search text, food details, booking details or what an action was about. Turning this off stops collection and clears the active summary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Prepare my JSON export", systemImage: "square.and.arrow.up") {
                        Task { await viewModel.exportUsageHistory() }
                    }
                    .disabled(viewModel.isManagingUsageHistory)

                    if let item = viewModel.usageHistoryExportItem {
                        ShareLink(item: item.url) {
                            Label("Share my JSON file", systemImage: "doc.badge.arrow.up")
                        }
                    }

                    Button(role: .destructive) {
                        showingClearUsageHistory = true
                    } label: {
                        Label("Clear my history", systemImage: "trash")
                    }
                    .disabled(viewModel.isManagingUsageHistory || !usageHistoryHasEvents(summary))
                } else {
                    Label("Off by default · nothing is recorded", systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("If you choose to enable it, content-free action facts are linked to your account for a private summary and used only to evaluate which HausKlar features help. There is no advertising or cross-app tracking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = viewModel.usageHistoryError {
                ContentUnavailableView {
                    Label("Usage choice unavailable", systemImage: "clock.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await viewModel.loadUsageHistory() } }
                }
            }

            if let error = viewModel.usageHistoryError,
               viewModel.usageHistorySummary != nil {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func usageActionSummary(_ summary: UsageHistorySummaryDTO) -> String {
        guard summary.meaningfulActions > 0 else {
            return String(localized: "No completed actions are in your recent history.")
        }
        return String.localizedStringWithFormat(
            String(localized: "Useful actions: %lld · days used: %lld"),
            Int64(summary.meaningfulActions),
            Int64(summary.activeDays)
        )
    }

    private func usageRepeatSummary(_ modules: [UsageModuleSummaryDTO]) -> String {
        String.localizedStringWithFormat(
            String(localized: "Used on more than one day: %@."),
            modules.map { usageModuleName($0.module) }.joined(separator: ", ")
        )
    }

    private func usageFailureSummary(_ count: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "Actions that didn’t finish: %lld. HausKlar does not keep the reason or what you entered."),
            Int64(count)
        )
    }

    private func usageScreenSummary(_ screens: [UsageScreenSummaryDTO]) -> String {
        let values = screens.prefix(5).map {
            "\(usageModuleName($0.module)) \($0.views)"
        }
        return "Most opened: \(values.joined(separator: ", "))."
    }

    private func usageControlSummary(_ controls: [UsageControlSummaryDTO]) -> String {
        let values = controls.prefix(5).map {
            "\(usageActionName($0.action)) \($0.presses)"
        }
        return "Buttons pressed: \(values.joined(separator: ", "))."
    }

    private func usageWorkflowSummary(_ workflow: UsageWorkflowSummaryDTO) -> String {
        var value = "\(usageActionName(workflow.action)): \(workflow.completions) of \(workflow.starts) completed"
        if workflow.failures + workflow.abandonments > 0 {
            value += ", \(workflow.failures + workflow.abandonments) did not finish"
        }
        if workflow.queuedCompletions > 0 {
            value += ", \(workflow.queuedCompletions) saved offline"
        }
        return value + "."
    }

    private func usageHistoryHasEvents(_ summary: UsageHistorySummaryDTO) -> Bool {
        summary.meaningfulActions > 0
            || summary.failedActions > 0
            || !summary.screenViews.isEmpty
            || !summary.controlUses.isEmpty
            || !summary.workflows.isEmpty
    }

    private func usageActionName(_ action: String) -> String {
        switch action {
        case "open_capture": String(localized: "Capture")
        case "open_add": String(localized: "Add")
        case "open_search": String(localized: "Search")
        case "open_more": String(localized: "More")
        case "open_fitness_log": String(localized: "Fitness log")
        case "open_fitness_coach": String(localized: "Fitness coach")
        case "open_swimming_booking", "book_swimming": String(localized: "Swimming booking")
        case "pull_strava": String(localized: "Strava pull")
        case "save_food_log", "quick_log_food", "save_meal_logs", "log_planned_meal", "log_meal_template":
            String(localized: "Food logging")
        default: action.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func usageModuleName(_ module: String) -> String {
        switch module {
        case "artwork": String(localized: "Artwork")
        case "calendar": String(localized: "Planner")
        case "capture": String(localized: "Capture")
        case "documents": String(localized: "Documents")
        case "dog": String(localized: "Dog care")
        case "family": String(localized: "Family")
        case "finance": String(localized: "Finance")
        case "fitness": String(localized: "Fitness")
        case "facilities": String(localized: "Facilities")
        case "homework": String(localized: "Homework")
        case "house": String(localized: "House")
        case "lists": String(localized: "Lists")
        case "meals": String(localized: "Meals")
        case "medicine": String(localized: "Medicine")
        case "navigation": String(localized: "Navigation")
        case "naps": String(localized: "Naps")
        case "presents": String(localized: "Presents")
        case "routines": String(localized: "Routines")
        case "search": String(localized: "Search")
        case "shopping": String(localized: "Shopping")
        case "stars": String(localized: "Star charts")
        case "tasks": String(localized: "Tasks")
        case "today": String(localized: "Today")
        default: module.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private var aiPrivacySection: some View {
        Section("AI & Family Data") {
            if viewModel.isLoadingAIConsent {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading AI privacy settings…")
                        .foregroundStyle(.secondary)
                }
            } else if let status = viewModel.aiConsentStatus {
                Label(
                    status.consented ? "OpenAI permission granted" : "OpenAI permission not granted",
                    systemImage: status.consented ? "checkmark.shield.fill" : "hand.raised.fill"
                )
                .foregroundStyle(status.consented ? Color.green : Color.secondary)

                Text(status.disclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label("No unattended or nightly AI processing", systemImage: "moon.zzz.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let privacyURL = SafeExternalURL.web("https://hausklar.example.invalid/privacy-policy") {
                    Link("Read the privacy policy", destination: privacyURL)
                }

                if let error = viewModel.aiConsentError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if status.consented {
                    Button("Withdraw AI Permission", systemImage: "hand.raised") {
                        Task { await viewModel.revokeAIConsent() }
                    }
                    .disabled(viewModel.isSavingAIConsent)
                } else {
                    Button("Allow OpenAI Processing", systemImage: "checkmark.shield") {
                        Task { await viewModel.grantAIConsent() }
                    }
                    .disabled(viewModel.isSavingAIConsent)
                }
            } else {
                ContentUnavailableView {
                    Label("Privacy settings unavailable", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(viewModel.aiConsentError ?? "Reconnect and try again.")
                } actions: {
                    Button("Try Again") { Task { await viewModel.loadAIConsent() } }
                }
            }
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section("Account") {
            HStack(spacing: 12) {
                Image(systemName: "person.example_a738933a.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $viewModel.userName)
                        .textContentType(.name)
                        .font(.headline)
                    if !viewModel.userEmail.isEmpty {
                        Text(viewModel.userEmail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !viewModel.userRole.isEmpty {
                        Text(viewModel.userRole.capitalized)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.vertical, 4)

            Button {
                Task { await viewModel.saveProfile(appState: appState) }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isSavingProfile { ProgressView().controlSize(.small) }
                    Label("Save profile", systemImage: "person.example_35fbacff.circle.badge.checkmark")
                }
            }
            .disabled(
                viewModel.isSavingProfile
                    || viewModel.userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.userName.trimmingCharacters(in: .whitespacesAndNewlines) == appState.currentUser?.name
            )

            if let message = viewModel.profileMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(message == "Profile saved." ? Color.green : Color.red)
            }

            Text("Your email is your secure sign-in identity. Change it through support so account access is verified first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var roleAndVisibilitySection: some View {
        Section("People, roles & visibility") {
            Label(
                isAdmin ? "You are a family administrator" : "You are a family member",
                systemImage: isAdmin ? "person.example_4163b177.key.fill" : "person.example_e864bc8d"
            )
            .fontWeight(.semibold)

            Text(isAdmin
                 ? "You can invite adults and manage household connections. This does not give you access to another adult’s private Finance or Fitness records."
                 : "You can use the shared planner and family records. An administrator manages people and household connections; your private adult areas remain yours.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.calendarMembers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading people…").foregroundStyle(.secondary)
                }
            } else {
                ForEach(viewModel.calendarMembers) { member in
                    HStack {
                        Label(
                            member.name,
                            systemImage: member.memberType == "child" ? "figure.child" : "person.example_35fbacff.circle"
                        )
                        Spacer()
                        Text(member.memberType == "child" ? "Child" : "Adult")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var securitySection: some View {
        Section("Security") {
            Button {
                showingChangePassword = true
            } label: {
                Label("Change Password", systemImage: "key.fill")
            }
            Text("Changing your password keeps this signed-in device active and revokes other sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var moneySection: some View {
        Section("Money") {
            NavigationLink {
                FinanceSimpleView(preferenceOwner: appState.currentUser?.id)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Money")
                        Text("Budgets, goals and spending")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sterlingsign.circle.fill")
                        .foregroundStyle(.blue)
                }
            }

            NavigationLink {
                RenewalsView()
            } label: {
                Label("Renewals linked to Household Finance", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var fitnessWorkspaceSection: some View {
        Section("Personal workspaces") {
            Toggle("Use Fitness", isOn: Binding(
                get: { appState.fitnessWorkspacePreference.enabled },
                set: { enabled in
                    Task { _ = await appState.updateFitnessWorkspace(enabled: enabled) }
                }
            ))
            .disabled(appState.isUpdatingFitnessWorkspace)

            if appState.fitnessWorkspacePreference.enabled {
                Toggle("Show nutrition progress on Today", isOn: Binding(
                    get: { appState.fitnessWorkspacePreference.showNutritionToday },
                    set: { show in
                        Task {
                            _ = await appState.updateFitnessWorkspace(
                                showNutritionToday: show
                            )
                        }
                    }
                ))
                .disabled(appState.isUpdatingFitnessWorkspace)

                Text("Displays your private calorie and protein running totals against today’s goals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    FitnessQuickEntrySettingsView()
                } label: {
                    Label("Meal-time shortcuts", systemImage: "clock.badge.checkmark")
                }
                .accessibilityIdentifier("fitnessMealTimeSettings")

                Button("Open Fitness", systemImage: "figure.run") {
                    appState.showingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        appState.openFitness(destination: .progress)
                    }
                }
            }

            if appState.isUpdatingFitnessWorkspace {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Saving Fitness preference…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = appState.fitnessWorkspaceErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Language Section

    private var remindersSection: some View {
        Section("Reminders") {
            Toggle("Upcoming events", isOn: $viewModel.reminderPreferences.eventRemindersEnabled)
            if viewModel.reminderPreferences.eventRemindersEnabled {
                Picker("Event warning", selection: $viewModel.reminderPreferences.eventMinutesBefore) {
                    Text("10 minutes before").tag(10)
                    Text("30 minutes before").tag(30)
                    Text("1 hour before").tag(60)
                    Text("1 day before").tag(1440)
                }
            }
            Toggle("Due tasks", isOn: $viewModel.reminderPreferences.taskRemindersEnabled)
            Toggle("Morning summary", isOn: $viewModel.reminderPreferences.morningSummaryEnabled)
            if viewModel.reminderPreferences.morningSummaryEnabled {
                DatePicker(
                    "Summary time",
                    selection: Binding(
                        get: { timeDate(viewModel.reminderPreferences.morningSummaryTime) },
                        set: { viewModel.reminderPreferences.morningSummaryTime = timeString($0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            Toggle("Tomorrow, sorted", isOn: $viewModel.reminderPreferences.eveningSummaryEnabled)
            if viewModel.reminderPreferences.eveningSummaryEnabled {
                DatePicker(
                    "Tomorrow check",
                    selection: Binding(
                        get: { timeDate(viewModel.reminderPreferences.eveningSummaryTime) },
                        set: { viewModel.reminderPreferences.eveningSummaryTime = timeString($0) }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            DatePicker("Quiet from", selection: Binding(
                get: { timeDate(viewModel.reminderPreferences.quietStart) },
                set: { viewModel.reminderPreferences.quietStart = timeString($0) }
            ), displayedComponents: .hourAndMinute)
            DatePicker("Quiet until", selection: Binding(
                get: { timeDate(viewModel.reminderPreferences.quietEnd) },
                set: { viewModel.reminderPreferences.quietEnd = timeString($0) }
            ), displayedComponents: .hourAndMinute)
            Toggle(isOn: Binding(
                get: { viewModel.reminderPreferences.privacyMode },
                set: { newValue in
                    guard newValue != viewModel.reminderPreferences.privacyMode else { return }
                    pendingPrivacyMode = newValue
                }
            )) {
                VStack(alignment: .leading) {
                    Text("Private lock-screen wording")
                    Text("Hide event and task names until HausKlar opens")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !viewModel.notificationsEnabled {
                if viewModel.notificationPermissionDenied {
                    Label("Notifications are blocked in iOS Settings", systemImage: "bell.slash.fill")
                        .foregroundStyle(.orange)
                    Button("Open iOS Settings", systemImage: "gear") {
                        viewModel.openNotificationSettings()
                    }
                    Text("In Settings, choose Notifications → Allow Notifications, then return to HausKlar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button { Task { await viewModel.enableNotifications() } } label: {
                        Label("Enable Notifications", systemImage: "bell.badge")
                    }
                }
            } else {
                Label("Notifications enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Send Test Reminder") {
                    Task { await NotificationService.shared.sendTestReminder() }
                }
            }
            HStack(spacing: 8) {
                if viewModel.isSavingReminders { ProgressView().controlSize(.small) }
                Label(
                    viewModel.isSavingReminders ? "Saving changes…" : "Changes save automatically",
                    systemImage: viewModel.isSavingReminders ? "arrow.triangle.2.circlepath" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let error = viewModel.reminderError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if viewModel.reminderPreview.isEmpty {
                Text("All clear—there are no reminders in the next two days.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reminderPreview.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).fontWeight(.semibold)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func timeDate(_ value: String) -> Date {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 7, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: Date()) ?? Date()
    }

    private func timeString(_ date: Date) -> String {
        String(format: "%02d:%02d", Calendar.current.component(.hour, from: date), Calendar.current.component(.minute, from: date))
    }

    private var isAdmin: Bool {
        appState.currentUser?.role.lowercased() == "admin"
    }

    private var familyInviteSection: some View {
        Section("Invite another adult") {
            if let code = viewModel.inviteCode {
                if let inviteURL = viewModel.inviteURL {
                    VStack(spacing: 10) {
                        InviteQRCode(value: inviteURL)
                            .frame(width: 168, height: 168)
                            .accessibilityLabel("Family invite QR code")
                        Text("Scan to open HausKlar with the invite filled in")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                HStack {
                    Text("Invite Code")
                    Spacer()
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.semibold)
                }

                HStack {
                    Button {
                        SensitiveClipboard.copy(
                            code,
                            expiresAt: viewModel.inviteExpiresAt.flatMap(ISODateParser.parse),
                            maximumLifetime: 120
                        )
                    } label: {
                        Label("Copy Code for 2 Minutes", systemImage: "doc.on.doc")
                    }

                    Spacer()

                    ShareLink(item: code) {
                        Label("Share code", systemImage: "square.and.arrow.up")
                    }
                }

                if let inviteURL = viewModel.inviteURL, let url = URL(string: inviteURL) {
                    ShareLink(item: url) {
                        Label("Share join link", systemImage: "link")
                    }
                }

                if let expiresAt = viewModel.inviteExpiresAt {
                    Text(inviteExpiryDescription(expiresAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task {
                    await viewModel.generateInviteCode()
                }
            } label: {
                HStack {
                    if viewModel.isGeneratingInviteCode {
                        ProgressView()
                    }
                    Text(viewModel.inviteCode == nil ? "Create secure invite" : "Replace secure invite")
                }
            }
            .disabled(viewModel.isGeneratingInviteCode)

            Text("The other adult gets their own login. Shared family information is visible to both of you; private adult workspaces remain separate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func inviteExpiryDescription(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            return "This invite expires automatically."
        }
        return "Invite expires \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    private func connectionDateDescription(_ value: String) -> String {
        guard let date = ISODateParser.parse(value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Calendar Connections

    private var rugbyConnectionsSection: some View {
        Section("Example School Rugby") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keep one Example School rugby team in the family planner")
                    .fontWeight(.semibold)
                Text("HausKlar checks Example School College Sports automatically and keeps fixture changes up to date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.isLoadingRugby {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading rugby teams…")
                        .foregroundStyle(.secondary)
                }
            } else if let teams = viewModel.rugbyTeams {
                Picker("Rugby team", selection: $viewModel.selectedRugbyTeamId) {
                    Text("Choose a team").tag("")
                    if let currentId = viewModel.rugbySettings.teamId,
                       !teams.teams.contains(where: { $0.id == currentId }) {
                        Text(viewModel.rugbySettings.teamName ?? "Current team")
                            .tag(currentId)
                    }
                    ForEach(teams.teams) { team in
                        Text(team.name).tag(team.id)
                    }
                }
                .disabled(viewModel.isManagingRugby)

                Text("\(teams.season) season · Example School College Sports")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 9) {
                Label("Every fixture reserves 1:00–7:00 pm", systemImage: "clock.example_c6e20e62")
                    .fontWeight(.semibold)
                HStack(spacing: 8) {
                    Text("HOME")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.blue, in: RoundedRectangle(cornerRadius: 6))
                    Text("AWAY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.red, in: RoundedRectangle(cornerRadius: 6))
                    Text("Away blocks are red throughout the planner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.rugbySettings.configured {
                    Text(
                        "\(viewModel.rugbySettings.ownerName ?? "Calendar owner") is attending"
                            + (viewModel.rugbySettings.affectedNames.isEmpty
                                ? "."
                                : " · affects \(viewModel.rugbySettings.affectedNames.joined(separator: " & ")).")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if let lastError = viewModel.rugbySettings.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let error = viewModel.rugbyError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Try Again") {
                        Task { await viewModel.loadRugbySettings() }
                    }
                }
            }
            if let notice = viewModel.rugbyNotice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button {
                Task { await viewModel.saveRugbyTeam() }
            } label: {
                HStack {
                    if viewModel.isManagingRugby { ProgressView().controlSize(.small) }
                    Label(
                        viewModel.rugbySettings.configured ? "Save Rugby Team" : "Connect Rugby Team",
                        systemImage: "sportscourt"
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .disabled(viewModel.isManagingRugby || viewModel.selectedRugbyTeamId.isEmpty)

            if viewModel.rugbySettings.configured {
                Button {
                    Task { await viewModel.refreshRugbyFixtures() }
                } label: {
                    Label("Refresh Fixtures", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(viewModel.isManagingRugby)

                if let lastSuccess = viewModel.rugbySettings.lastSuccessAt {
                    Text("Last checked \(connectionDateDescription(lastSuccess))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var calendarConnectionsSection: some View {
        Section("Calendar Connections") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bring an existing calendar into the family planner")
                    .fontWeight(.semibold)
                Text("Paste its private subscription link. HausKlar checks the calendar before saving anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Calendar name", text: $viewModel.calendarSourceName)
                .onChange(of: viewModel.calendarSourceName) { _, _ in viewModel.calendarCandidateChanged() }
            TextField("Private ICS link", text: $viewModel.calendarSourceURL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                .onChange(of: viewModel.calendarSourceURL) { _, _ in viewModel.calendarCandidateChanged() }

            Picker("Show as", selection: $viewModel.calendarSourcePerson) {
                Text("Whole family").tag("")
                ForEach(viewModel.calendarMembers) { member in
                    Text(member.name).tag(member.id)
                }
            }
            .onChange(of: viewModel.calendarSourcePerson) { _, _ in viewModel.calendarCandidateChanged() }

            Button {
                Task { await viewModel.validateCalendarSource() }
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isManagingCalendars && viewModel.calendarValidation == nil {
                        ProgressView().controlSize(.small)
                    }
                    Label("Check calendar", systemImage: "checkmark.shield")
                }
            }
            .disabled(
                viewModel.isManagingCalendars
                    || viewModel.calendarSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.calendarSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            if let validation = viewModel.calendarValidation, validation.valid {
                Label(
                    "Connected to \(validation.hostname) · \(validation.eventCount) event\(validation.eventCount == 1 ? "" : "s") found",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }

            Button {
                Task { await viewModel.addCalendarSource() }
            } label: {
                HStack {
                    if viewModel.isManagingCalendars { ProgressView().controlSize(.small) }
                    Label("Add Calendar", systemImage: "calendar.badge.plus")
                }
            }
            .disabled(
                viewModel.isManagingCalendars
                    || viewModel.calendarSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.calendarSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || viewModel.calendarValidation?.valid != true
            )

            ForEach(viewModel.calendarSources) { source in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color(hex: source.color))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).fontWeight(.semibold)
                        Text(source.hostname)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = source.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await viewModel.syncCalendarSource(source) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isManagingCalendars || !source.enabled)
                    Button(role: .destructive) {
                        calendarSourcePendingDeletion = source
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Use HausKlar in another calendar").fontWeight(.semibold)
                Text("Create a private read-only link for Apple, Google or Outlook. It is shown once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(viewModel.calendarFeedConfigured ? "Replace Link" : "Create Link") {
                    if viewModel.calendarFeedConfigured {
                        showingReplaceFeedAlert = true
                    } else {
                        Task { await viewModel.rotateCalendarFeed() }
                    }
                }
                if let link = viewModel.newCalendarFeedURL {
                    HStack {
                        Text(link)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            SensitiveClipboard.copy(link, maximumLifetime: 120)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("Copy private calendar link for 2 minutes")
                        if let url = URL(string: link) {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
            }

            if let error = viewModel.calendarError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Text("Imported events are read-only. HausKlar refreshes them every 30 minutes and never displays the stored private link.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Home Assistant Section

    private var homeAssistantSection: some View {
        Section("Home Dashboard") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect the household dashboard")
                    .fontWeight(.semibold)
                Text("Check the connection with the details below. Nothing is saved until the check succeeds and you choose Save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced connection details") {
                TextField("Dashboard URL", text: $viewModel.haDashboardURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))

                TextField("Home Assistant URL", text: $viewModel.haURL)
                    .textContentType(.URL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: viewModel.haURL) { _, _ in viewModel.haCandidateChanged() }

                SecureField(
                    viewModel.haTokenConfigured ? "Replace HA access token" : "HA access token",
                    text: $viewModel.haToken
                )
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: viewModel.haToken) { _, _ in viewModel.haCandidateChanged() }

                Text("Create a long-lived token in Home Assistant → Profile → Security. It is sent directly to the HausKlar server and is never stored on this iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.haTokenConfigured {
                Label("Token stored securely on the HausKlar server", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Button {
                    Task {
                        await viewModel.testHAConnection()
                    }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.haConnectionStatus == .testing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Test Connection")
                    }
                }
                .disabled(
                    viewModel.haURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (!viewModel.haTokenConfigured && viewModel.haToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        || viewModel.haConnectionStatus == .testing
                )

                Spacer()

                switch viewModel.haConnectionStatus {
                case .success:
                    Label("Connection checked", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failure:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }

            if case .failure(let message) = viewModel.haConnectionStatus {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task {
                    await viewModel.saveHASettings()
                }
            } label: {
                HStack {
                    if viewModel.isSavingHA {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save")
                }
            }
            .disabled(viewModel.isSavingHA || viewModel.haConnectionStatus != .success)

            if let error = viewModel.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var languageSection: some View {
        Section("Language") {
            Picker("Language", selection: $languageManager.selectedLanguage) {
                ForEach(LanguageManager.Language.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
        }
    }

    // MARK: - Babysitter Mode Section

    private var babysitterSection: some View {
        Section {
            NavigationLink {
                BabysitterModeView()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.example_4163b177.key")
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Babysitter handover")
                            .font(.body)
                        Text("Prepare details and create private access")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - App Info Section

    private var appInfoSection: some View {
        Section("App") {
            HStack {
                Text("Version")
                Spacer()
                Text("HausKlar v\(appVersion)")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Platform")
                Spacer()
                Text("iOS 17+")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    // MARK: - Legal Section

    private var legalSection: some View {
        Section("Legal") {
            if let supportURL = SafeExternalURL.web("https://hausklar.example.invalid/support") {
                Link("Contact Support", destination: supportURL)
            }
            if let privacyURL = SafeExternalURL.web("https://hausklar.example.invalid/privacy-policy") {
                Link("Privacy Policy", destination: privacyURL)
            }
            if let termsURL = SafeExternalURL.web("https://hausklar.example.invalid/terms") {
                Link("Terms of Service", destination: termsURL)
            }
        }
    }

    // MARK: - Logout Section

    private var logoutSection: some View {
        Section {
            Button(role: .destructive) {
                Task {
                    isCheckingLogout = true
                    logoutSyncWarning = nil
                    do {
                        try await refreshPendingLogoutWork()
                    } catch {
                        logoutSafetyErrorMessage = "HausKlar could not verify whether private Fitness work is waiting to sync. Nothing was removed. Try again before logging out."
                        showingLogoutSafetyError = true
                        settingsLogoutLogger.error(
                            "Logout was stopped because pending work could not be counted: \(error.localizedDescription, privacy: .private)"
                        )
                        isCheckingLogout = false
                        return
                    }
                    isCheckingLogout = false
                    if unsyncedItemCount > 0 {
                        showingLogoutDiscardAlert = true
                    } else {
                        await appState.logoutAndRevoke()
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Group {
                        if isCheckingLogout {
                            ProgressView()
                        } else {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                    .fontWeight(.semibold)
                    Spacer()
                }
            }
            .disabled(isCheckingLogout)
        }
    }

    private var unsyncedItemCount: Int {
        offlineActions.filter { $0.status != .synced }.count
            + pendingDocumentUploads.count
            + pendingFitnessItemCount
            + pendingHTTPMutationCount
    }

    @MainActor
    private func refreshPendingLogoutWork() async throws {
        // Publish the combined count only after the throwing database read has
        // succeeded. An unavailable store is unknown, never equivalent to zero.
        let databaseCount = try FitnessDatabase.shared.pendingLocalWorkCount()
        let inboxCount = FitnessDatabase.shared.activeIdentity.map {
            FitnessPendingFITInbox.pendingCount(identity: $0)
        } ?? 0
        let httpMutationCount = await APIClient.shared.pendingOfflineMutationCount()
        pendingFitnessItemCount = databaseCount + inboxCount
        pendingHTTPMutationCount = httpMutationCount
    }

    @MainActor
    private func syncPendingLogoutWork() async {
        await SyncManager.shared.syncNow(modelContext: modelContext)
        await DocumentUploadService.shared.flush(modelContext: modelContext)
        do {
            try await FitnessSyncService.shared.syncNow()
        } catch {
            logoutSyncWarning = "Fitness sync did not finish: \(error.localizedDescription)."
            settingsLogoutLogger.error(
                "Manual pre-logout Fitness sync failed: \(error.localizedDescription, privacy: .private)"
            )
        }
        await APIClient.shared.flushOfflineMutations()
        do {
            try await refreshPendingLogoutWork()
        } catch {
            logoutSafetyErrorMessage = "HausKlar could not re-check private Fitness work after syncing. Nothing was removed. Try again before logging out."
            showingLogoutSafetyError = true
            settingsLogoutLogger.error(
                "Post-sync logout-safety count failed: \(error.localizedDescription, privacy: .private)"
            )
            return
        }
        if unsyncedItemCount > 0 {
            showingLogoutDiscardAlert = true
        }
    }

    // MARK: - Danger Zone Section

    private var dangerZoneSection: some View {
        Section("Danger Zone") {
            Button(role: .destructive) {
                showingDeleteAccountAlert = true
            } label: {
                HStack(spacing: 8) {
                    if viewModel.isDeletingAccount {
                        ProgressView()
                    }
                    Image(systemName: "person.example_35fbacff.circle.badge.xmark")
                    Text("Delete Account")
                }
            }
            .disabled(viewModel.isDeletingAccount)

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Permanently deletes your account, private settings and identity links. Shared household records remain anonymously for other members; the final account also removes all live family records and uploaded files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Disclaimer Section

    private var disclaimerSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "cross.case")
                    .foregroundStyle(.orange)
                Text("This app provides reminders only, not medical advice. Always consult a healthcare professional for medical decisions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct FitnessQuickEntrySettingsView: View {
    @StateObject private var viewModel = FitnessQuickEntrySettingsViewModel()
    @State private var breakfast = Date()
    @State private var lunch = Date()
    @State private var dinner = Date()
    @State private var didSeed = false

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "Breakfast",
                    selection: $breakfast,
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Lunch",
                    selection: $lunch,
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Dinner",
                    selection: $dinner,
                    displayedComponents: .hourAndMinute
                )
            } header: {
                Text("Meal times")
            } footer: {
                Text("Today offers a quick Nutrition shortcut for the nearest meal, from 90 minutes before until 90 minutes after this time.")
            }

            if viewModel.isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading meal times…")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if viewModel.isFromCache, !viewModel.isLoading {
                Section {
                    Label("Saved times shown while offline", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.usesDefaults, !viewModel.isLoading {
                Section {
                    Label("Standard times shown — save to use them as yours", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = viewModel.message {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try again") { Task { await load() } }
                        .disabled(viewModel.isLoading || viewModel.isSaving)
                }
            }
        }
        .navigationTitle("Meal-time shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        _ = await viewModel.save(
                            FitnessQuickEntryMealTimes(
                                breakfast: FitnessQuickEntryPolicy.wireTime(from: breakfast),
                                lunch: FitnessQuickEntryPolicy.wireTime(from: lunch),
                                dinner: FitnessQuickEntryPolicy.wireTime(from: dinner)
                            )
                        )
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(viewModel.isLoading || viewModel.isSaving)
                .accessibilityIdentifier("saveFitnessMealTimes")
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(viewModel.isSaving)
        .accessibilityIdentifier("fitnessMealTimeSettingsView")
    }

    private func load() async {
        await viewModel.load()
        seed(viewModel.mealTimes)
    }

    private func seed(_ values: FitnessQuickEntryMealTimes) {
        guard !didSeed || !viewModel.isFromCache else { return }
        let reference = Date()
        breakfast = FitnessQuickEntryPolicy.date(
            for: values.breakfast,
            on: reference
        ) ?? breakfast
        lunch = FitnessQuickEntryPolicy.date(
            for: values.lunch,
            on: reference
        ) ?? lunch
        dinner = FitnessQuickEntryPolicy.date(
            for: values.dinner,
            on: reference
        ) ?? dinner
        didSeed = true
    }
}

struct FirstFamilyOnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: FirstFamilyOnboardingViewModel
    let onComplete: (OnboardingStatusDTO) -> Void

    init(status: OnboardingStatusDTO, onComplete: @escaping (OnboardingStatusDTO) -> Void) {
        _viewModel = StateObject(wrappedValue: FirstFamilyOnboardingViewModel(status: status))
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Getting started · \(viewModel.step.rawValue + 1) of 4")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            Text(stepTitle)
                                .font(.largeTitle.bold())
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }

                        if let error = viewModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        }

                        switch viewModel.step {
                        case .welcome: welcomeStep
                        case .firstCommitment: firstCommitmentStep
                        case .people: peopleStep
                        case .preferences: choicesStep
                        }
                    }
                    .id("firstFamilyOnboardingTop")
                    .padding(24)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    onboardingFooter
                }
                .onChange(of: viewModel.step) { _, _ in
                    scrollProxy.scrollTo("firstFamilyOnboardingTop", anchor: .top)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") {
                        Task {
                            if let status = await viewModel.dismiss() { onComplete(status) }
                        }
                    }
                    .disabled(viewModel.isBusy)
                }
            }
            .task(id: viewModel.step) {
                await viewModel.loadReminderChoices()
            }
        }
        .interactiveDismissDisabled()
    }

    private var stepTitle: LocalizedStringKey {
        switch viewModel.step {
        case .welcome: "Welcome to your family’s shared plan"
        case .firstCommitment: "Put the first real thing in the planner"
        case .people: "Who should HausKlar understand?"
        case .preferences: viewModel.completionStatus == nil ? "Choose useful reminders" : "You know what’s happening today"
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("HausKlarLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)

            Text("Know what’s happening today.")
                .font(.title2.bold())

            Text("HausKlar keeps the detail your family may need—people, commitments, documents and specialist records—behind one calm daily plan. We’ll establish only the useful core now.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(spacing: 10) {
                    LabeledContent("Household", value: viewModel.status.familyName)
                    Divider()
                    LabeledContent("People already here", value: "\(viewModel.status.peopleCount)")
                    Divider()
                    LabeledContent("Planner commitments", value: "\(viewModel.status.calendarCommitmentCount)")
                }
            }
        }
    }

    private var peopleStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Adults have their own secure sign-in. Children have profiles managed by the adults; they do not get accounts or see private adult areas.")
                .foregroundStyle(.secondary)

            if appState.currentUser?.role.lowercased() == "admin" {
                GroupBox("Invite the other adult") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The invitation is single-use and expires automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let inviteURL = viewModel.inviteURL {
                            InviteQRCode(value: inviteURL)
                                .frame(width: 168, height: 168)
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("QR code to join this household")
                            if let code = viewModel.inviteCode {
                                Text(code)
                                    .font(.title3.monospaced().weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            if let url = URL(string: inviteURL) {
                                ShareLink(item: url) {
                                    Label("Share secure join link", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                        if viewModel.inviteURL == nil {
                            Button("Create invitation") {
                                Task { await viewModel.generateInvite() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isBusy)
                        } else {
                            Button("Replace invitation") {
                                Task { await viewModel.generateInvite() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isBusy)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Add a child profile") {
                VStack(spacing: 12) {
                    TextField("Name", text: $viewModel.childName)
                        .textContentType(.name)
                        .textFieldStyle(.roundedBorder)
                    DatePicker(
                        "Date of birth",
                        selection: $viewModel.childDateOfBirth,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    Button("Add child", systemImage: "person.example_4163b177.plus") {
                        Task { await viewModel.addChild() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBusy || viewModel.childName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Label(peopleEstablishedSummary, systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
    }

    private var firstCommitmentStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("This is the first moment HausKlar becomes useful. Add one real commitment; school, work and shared calendars can be connected later under Settings → Connections.")
                .foregroundStyle(.secondary)

            if viewModel.status.firstSuccess {
                GroupBox {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your family plan has started").font(.headline)
                            Text("HausKlar can now answer the question that matters: what’s happening today?")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                GroupBox("First commitment") {
                    VStack(spacing: 12) {
                        TextField("What’s happening?", text: $viewModel.eventTitle, prompt: Text("School pickup"))
                            .textFieldStyle(.roundedBorder)
                        DatePicker("When?", selection: $viewModel.eventDate)
                        Picker("Duration", selection: $viewModel.eventDuration) {
                            ForEach(FirstCommitmentDuration.allCases) { duration in
                                Text(duration.title).tag(duration)
                            }
                        }
                        Label("Shared with everyone in the family", systemImage: "person.example_f47e224f.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Add first commitment", systemImage: "calendar.badge.plus") {
                            Task { await viewModel.addFirstCommitment() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isBusy || viewModel.eventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var choicesStep: some View {
        if viewModel.completionStatus != nil {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("Know what’s happening today.")
                    .font(.title2.bold())
                if viewModel.status.firstSuccess {
                    Text("Your first commitment is in the shared planner. The detail is there when you need it; Today stays calm.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Your choices are saved. Add the first real commitment when it becomes useful.")
                        .foregroundStyle(.secondary)
                }

                if viewModel.notificationPermissionDenied {
                    Label("Notifications are blocked in iOS Settings", systemImage: "bell.slash.fill")
                        .foregroundStyle(.orange)
                    Button("Open iOS Settings", systemImage: "gear") {
                        viewModel.openNotificationSettings()
                    }
                    Text("In Settings, choose Notifications → Allow Notifications, then return to HausKlar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 18) {
                Text("Start quiet. Specialist areas stay out of the way unless they genuinely fit your life.")
                    .foregroundStyle(.secondary)

                GroupBox("Useful reminders") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(OnboardingReminderChoice.allCases) { choice in
                            onboardingReminderToggle(choice)
                        }
                        Divider()
                        Toggle("Allow reminders on this iPhone", isOn: $viewModel.enableDeviceNotifications)
                        Text("iOS asks for permission only if you choose this.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Fitness") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(OnboardingModuleDTO.nativeSetupChoices) { module in
                            Toggle(isOn: Binding(
                                get: { viewModel.selectedModules.contains(module) },
                                set: { selected in
                                    if selected { viewModel.selectedModules.insert(module) }
                                    else { viewModel.selectedModules.remove(module) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(module.title)
                                    Text(module.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var onboardingFooter: some View {
        VStack(spacing: 0) {
            Divider()

            Group {
                switch viewModel.step {
                case .welcome:
                    primaryButton("Add the first commitment", icon: "calendar.badge.plus") {
                        viewModel.step = .firstCommitment
                    }
                case .firstCommitment:
                    stepButtons(
                        back: .welcome,
                        nextTitle: viewModel.status.firstSuccess ? "Add family details" : "Set up people instead"
                    ) {
                        viewModel.step = .people
                    }
                case .people:
                    stepButtons(back: .firstCommitment, nextTitle: "Choose reminders") {
                        viewModel.step = .preferences
                    }
                case .preferences:
                    if let status = viewModel.completionStatus {
                        primaryButton("Open Today", icon: "sun.max.fill") {
                            onComplete(status)
                        }
                    } else {
                        finishSetupButtons
                    }
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func onboardingReminderToggle(_ choice: OnboardingReminderChoice) -> some View {
        switch choice {
        case .commitments:
            Toggle("Upcoming commitments", isOn: $viewModel.reminderPreferences.eventRemindersEnabled)
        case .tasks:
            Toggle("Due tasks", isOn: $viewModel.reminderPreferences.taskRemindersEnabled)
        case .morningSummary:
            Toggle("Morning summary", isOn: $viewModel.reminderPreferences.morningSummaryEnabled)
        case .eveningSummary:
            Toggle("Tomorrow, sorted", isOn: $viewModel.reminderPreferences.eveningSummaryEnabled)
        }
    }

    private var peopleEstablishedSummary: String {
        String.localizedStringWithFormat(
            String(localized: "People established: %lld"),
            Int64(viewModel.status.peopleCount)
        )
    }

    private func primaryButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
    }

    private func stepButtons(
        back: FirstFamilyOnboardingStep,
        nextTitle: LocalizedStringKey,
        next: @escaping () -> Void
    ) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stepButtonsVertical(back: back, nextTitle: nextTitle, next: next)
            } else {
                ViewThatFits(in: .horizontal) {
                    stepButtonsHorizontal(back: back, nextTitle: nextTitle, next: next)
                    stepButtonsVertical(back: back, nextTitle: nextTitle, next: next)
                }
            }
        }
        .disabled(viewModel.isBusy)
    }

    private func stepButtonsHorizontal(
        back: FirstFamilyOnboardingStep,
        nextTitle: LocalizedStringKey,
        next: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button { viewModel.step = back } label: {
                Text("Back").frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
            Button(action: next) {
                Text(nextTitle).frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func stepButtonsVertical(
        back: FirstFamilyOnboardingStep,
        nextTitle: LocalizedStringKey,
        next: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: next) {
                Text(nextTitle).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Button { viewModel.step = back } label: {
                Text("Back").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var finishSetupButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            finishSetupButtons(vertical: true)
        } else {
            ViewThatFits(in: .horizontal) {
                finishSetupButtons(vertical: false)
                finishSetupButtons(vertical: true)
            }
        }
    }

    private func finishSetupButtons(vertical: Bool) -> some View {
        Group {
            if vertical {
                VStack(spacing: 8) {
                    finishSetupButton
                    onboardingBackToPeopleButton
                }
            } else {
                HStack(spacing: 12) {
                    onboardingBackToPeopleButton
                    Spacer(minLength: 0)
                    finishSetupButton
                }
            }
        }
        .disabled(viewModel.isBusy)
    }

    private var onboardingBackToPeopleButton: some View {
        Button { viewModel.step = .people } label: {
            Text("Back").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private var finishSetupButton: some View {
        Button {
            Task { _ = await viewModel.finish(appState: appState) }
        } label: {
            Group {
                if viewModel.isBusy { ProgressView() }
                else { Text("Finish setup") }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct InviteQRCode: View {
    let value: String

    var body: some View {
        if let image = makeImage() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .padding(24)
                .foregroundStyle(.secondary)
        }
    }

    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(LanguageManager())
}
