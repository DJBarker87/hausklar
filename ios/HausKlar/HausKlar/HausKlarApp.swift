import SwiftUI
import SwiftData

// Versioned schemas live beside the persisted models so released snapshots
// cannot accidentally acquire properties from a future live model.

// MARK: - App

@main
struct HausKlarApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var languageManager = LanguageManager()
    @StateObject private var modelContainerLoader = HausKlarModelContainerLoader()
    @State private var pendingAmbientRoute: HausKlarDeepLink?
    @State private var pendingAmbientOwnerID: String?
    @State private var isPrivacyCovered = true
    @UIApplicationDelegateAdaptor(HausKlarNotificationDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(LocalStoreRecovery.recoveryFlag) private var didRecoverLocalStore = false

    var body: some Scene {
        WindowGroup {
            rootContent
                .task { await modelContainerLoader.load() }
                .onReceive(NotificationCenter.default.publisher(for: .hausklarReminderOpened)) { notification in
                    if let value = notification.object as? String {
                        appState.openReminderURL(value)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .ambientIntentRouteReady)) { _ in
                    consumeAmbientIntentRoute()
                }
                .onChange(of: scenePhase) {
                    updatePrivacyCover()
                    if scenePhase == .active {
                        MedicineActivityManager.shared.endExpired()
                    }
                    if scenePhase == .active && appState.isAuthenticated {
                        openPendingAmbientRoute()
                        consumeAmbientIntentRoute()
                        appState.consumeSharedCapture()
                        Task { await NotificationService.shared.refreshHausKlarReminders() }
                    }
                }
                .onChange(of: appState.isAuthenticated) {
                    updatePrivacyCover()
                    if appState.isAuthenticated {
                        openPendingAmbientRoute()
                        consumeAmbientIntentRoute()
                        appState.consumeSharedCapture()
                        Task { await NotificationService.shared.refreshHausKlarReminders() }
                    } else {
                        pendingAmbientRoute = nil
                        pendingAmbientOwnerID = nil
                    }
                }
                .onOpenURL { url in
                    openHausKlarURL(url)
                }
        }
        .environmentObject(appState)
        .environmentObject(networkMonitor)
        .environmentObject(languageManager)
    }

    @ViewBuilder
    private var rootContent: some View {
        if let modelContainerLoad = modelContainerLoader.result,
           let sharedModelContainer = modelContainerLoad.container {
            protectedAppContent(modelContainer: sharedModelContainer)
        } else if modelContainerLoader.result != nil {
            ContentUnavailableView(
                "Storage Error",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text("HausKlar could not initialize local storage. Restart the app or reinstall if this persists.")
            )
        } else {
            VStack(spacing: 14) {
                ProgressView()
                Text("Opening protected family data…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func protectedAppContent(modelContainer: ModelContainer) -> some View {
        Group {
            if appState.isSecuringLocalData {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Securing local family data…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.isAuthenticated {
                if appState.mustChangePassword {
                    ChangePasswordView()
                } else {
                    MainTabView()
                }
            } else {
                LoginView()
            }
        }
        .environment(\.locale, languageManager.locale)
        .overlay {
            if isPrivacyCovered && appState.isAuthenticated {
                AppPrivacyCover()
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .onAppear {
            updatePrivacyCover()
            appState.configureLocalIdentityBoundary(
                modelContext: modelContainer.mainContext
            )
            DocumentPreviewStore.purgeAllInBackground()
            DocumentCaptureService.purgeTemporaryCapturesInBackground()
            Task.detached(priority: .utility) {
                DocumentUploadService.hardenStoredUploadsOnDisk()
            }
            networkMonitor.start()
            APIClient.shared.onAuthFailure = { [weak appState] failedSession in
                Task { @MainActor in
                    guard APIClient.shared.isCurrentSession(failedSession) else { return }
                    await appState?.lockForReauthentication()
                }
            }
            APIClient.shared.onMutationCommitted = {
                WidgetReloader.shared.requestReload()
            }
            Task { await appState.restoreSession() }
            // Permission request deferred to first relevant feature interaction
            NotificationService.shared.setupCategories()
        }
        .modelContainer(modelContainer)
        .alert("Local storage repaired", isPresented: $didRecoverLocalStore) {
            Button("OK") { didRecoverLocalStore = false }
        } message: {
            Text("HausKlar made a fresh local copy from the family server. Any changes that had not synced may need to be entered again.")
        }
        .alert("HausKlar", isPresented: Binding(
            get: { appState.localDataNoticeMessage != nil },
            set: { if !$0 { appState.localDataNoticeMessage = nil } }
        )) {
            Button("OK") { appState.localDataNoticeMessage = nil }
        } message: {
            Text(appState.localDataNoticeMessage ?? "")
        }
        .alert("Local data needs attention", isPresented: Binding(
            get: { appState.localDataErrorMessage != nil },
            set: { if !$0 { appState.localDataErrorMessage = nil } }
        )) {
            Button("OK") { appState.localDataErrorMessage = nil }
        } message: {
            Text(appState.localDataErrorMessage ?? "Restart the app and try again. Any available Fitness recovery copy remains shareable on the sign-in screen.")
        }
    }

    private func updatePrivacyCover() {
        isPrivacyCovered = AppPrivacyCoverPolicy.shouldCover(
            isAuthenticated: appState.isAuthenticated,
            scenePhase: scenePhase
        )
    }

    private func consumeAmbientIntentRoute() {
        guard appState.isAuthenticated,
              let route = AmbientIntentRouteStore.take() else { return }
        openHausKlarRoute(route)
    }

    private func openPendingAmbientRoute() {
        guard appState.isAuthenticated, let route = pendingAmbientRoute else { return }
        defer {
            pendingAmbientRoute = nil
            pendingAmbientOwnerID = nil
        }
        if let pendingAmbientOwnerID,
           pendingAmbientOwnerID != appState.currentUser?.id {
            return
        }
        openHausKlarRoute(route)
    }

    private func openHausKlarURL(_ url: URL) {
        guard let route = HausKlarDeepLink(url: url) else { return }
        guard appState.isAuthenticated else {
            pendingAmbientRoute = route
            pendingAmbientOwnerID = appState.currentUser?.id
            return
        }
        openHausKlarRoute(route)
    }

    private func openHausKlarRoute(_ route: HausKlarDeepLink) {
        switch route {
        case .capture(let text):
            appState.consumeSharedCapture()
            if !appState.showingUniversalCapture && !appState.showingDocumentCapture {
                appState.openCapturedText(text)
            }
        case .today:
            appState.selectedTab = .today
        case .calendar(let eventID):
            appState.highlightedCalendarResultId = eventID
            appState.selectedTab = .calendar
        case .medicine(let childID, let medicineTypeID):
            appState.openMedicineReview(
                childId: childID,
                medicineTypeId: medicineTypeID
            )
        case .naps(let napID, let childID):
            appState.openActiveNap(
                napId: napID,
                childId: childID
            )
        case .dog:
            appState.openFamily(.dog)
        case .starChart(let chartID, let childID):
            appState.openStarChart(
                chartId: chartID,
                childId: childID
            )
        case .photos(let assetID):
            if let assetID {
                appState.openPhoto(assetId: assetID)
            } else {
                appState.openFamily(.photos)
            }
        case .fitnessImports:
            appState.openFitness(destination: .activities, actionKind: "open_imports")
            Task { await FitnessActivityService.shared.processInboxNow() }
        case .fitnessWithings:
            appState.openFitness(destination: .progress, actionKind: "open_measurements")
        }
    }
}
