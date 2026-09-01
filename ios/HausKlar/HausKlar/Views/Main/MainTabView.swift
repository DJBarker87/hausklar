import SwiftUI
import os

private let mainTabViewLogger=Logger(
    subsystem:"org.example.hausklar",category:"MainTabView"
)

// MARK: - Lazy View

/// Defers creation of a view until it is actually rendered.
/// Used to avoid eagerly initialising every tab's view hierarchy at launch.
struct LazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }
    var body: some View { build() }
}

// MARK: - Sidebar Adaptable (iOS 18+)

/// Applies `.tabViewStyle(.sidebarAdaptable)` on iOS 18+; no-op on iOS 17.
private struct SidebarAdaptableModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

enum OnboardingCheckState: Equatable {
    case idle
    case checking
    case resolved
    case failed
}

// MARK: - Notification Name

extension Notification.Name {
    /// Posted when the app transitions to the background so views can persist pending form data.
    static let appDidEnterBackground = Notification.Name("appDidEnterBackground")
    static let calendarDataChanged = Notification.Name("hausklarCalendarDataChanged")
    static let taskDataChanged = Notification.Name("hausklarTaskDataChanged")
    static let shoppingDataChanged = Notification.Name("hausklarShoppingDataChanged")
}

/// The main tab bar shown after authentication.
/// Each tab corresponds to a major feature area of the app.
struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var syncManager = SyncManager.shared
    @StateObject private var assistantViewModel = AssistantChatViewModel()
    @State private var showingGlobalActions = false
    @State private var showingGlobalSearch = false
    @State private var showingMoreDestinations = false
    @State private var onboardingStatus: OnboardingStatusDTO?
    @State private var onboardingCheckState: OnboardingCheckState = .idle

    var body: some View {
        // This is structural layout, not an overlay. The TabView receives less
        // height, putting its system tab bar immediately above the global action
        // area while every tab's scrollable content remains unobscured.
        VStack(spacing: 0) {
            if networkMonitor.connectionState == .disconnected {
                OfflineIndicator()
            }

            if onboardingCheckState == .failed && networkMonitor.isConnected {
                onboardingRecoveryBanner
            }

            ZStack(alignment: .top) {
                TabView(selection: $appState.selectedTab) {
                    LazyView(DashboardView())
                        .tabItem {
                            Label("Today", systemImage: "calendar.badge.clock")
                        }
                        .tag(AppTab.today)

                    LazyView(CalendarView())
                        .tabItem {
                            Label("Calendar", systemImage: "calendar")
                        }
                        .tag(AppTab.calendar)

                    LazyView(FamilyTabView())
                        .tabItem {
                            Label("Family", systemImage: "figure.2.and.child.holdinghands")
                        }
                        .tag(AppTab.family)

                    ForEach(appState.visibleTabBarSlots) { destination in
                        customTabView(destination)
                        .tabItem {
                            Label(destination.title, systemImage: destination.systemImage)
                        }
                        .tag(destination.appTab)
                    }
                }
                .modifier(SidebarAdaptableModifier())

            }

            GlobalActionLauncher(
                isPresented: $showingGlobalActions,
                isFitness: appState.selectedTab == .fitness,
                openCapture: {
                    UsageMonitor.control(.openCapture(appState.selectedTab))
                    HapticManager.medium()
                    appState.openCapturedText(nil)
                },
                openAdd: {
                    UsageMonitor.control(.openAdd(appState.selectedTab))
                    HapticManager.medium()
                    appState.openAddHub()
                },
                openSearch: {
                    UsageMonitor.control(.openSearch(appState.selectedTab))
                    HapticManager.selection()
                    if appState.selectedTab == .fitness {
                        presentAfterGlobalActionsDismiss {
                            showingGlobalSearch = true
                        }
                    } else {
                        showingGlobalSearch = true
                    }
                },
                openMore: {
                    UsageMonitor.control(.openMore(appState.selectedTab))
                    HapticManager.selection()
                    presentAfterGlobalActionsDismiss {
                        showingMoreDestinations = true
                    }
                },
                openFitnessLog: {
                    UsageMonitor.control(.openFitnessLog(appState.selectedTab))
                    HapticManager.medium()
                    presentAfterGlobalActionsDismiss {
                        appState.openFitness(destination: .log)
                    }
                },
                openFitnessCoach: {
                    UsageMonitor.control(.openFitnessCoach(appState.selectedTab))
                    HapticManager.selection()
                    presentAfterGlobalActionsDismiss {
                        appState.openFitness(destination: .coach)
                    }
                }
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                NotificationCenter.default.post(name: .appDidEnterBackground, object: nil)
                syncManager.stopAutoSync()
                Task { await FitnessSyncService.shared.pausePeriodicSync() }
            } else if newPhase == .active {
                syncManager.startAutoSync(
                    modelContext: modelContext,
                    networkMonitor: networkMonitor
                )
                Task { await FitnessSyncService.shared.resumePeriodicSync() }
                if onboardingCheckState == .failed {
                    Task { await loadOnboardingIfNeeded() }
                }
                if networkMonitor.isConnected {
                    Task {
                        await syncManager.syncNow(modelContext: modelContext)
                        await DocumentUploadService.shared.flush(modelContext: modelContext)
                        do {
                            try await FitnessSyncService.shared.syncNow()
                        } catch is CancellationError {
                            return
                        } catch {
                            // FitnessSyncStatus owns the user-visible retry state.
                            mainTabViewLogger.error(
                                "Foreground Fitness sync failed: \(error.localizedDescription, privacy:.private)"
                            )
                        }
                    }
                }
            }
        }
        .task {
            UsageMonitor.screen(appState.selectedTab)
            syncManager.startAutoSync(modelContext: modelContext, networkMonitor: networkMonitor)
            if networkMonitor.isConnected {
                await DocumentUploadService.shared.flush(modelContext: modelContext)
                await loadOnboardingIfNeeded()
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, connected in
            guard connected else { return }
            Task {
                await syncManager.syncNow(modelContext: modelContext)
                await DocumentUploadService.shared.flush(modelContext: modelContext)
                await loadOnboardingIfNeeded()
            }
        }
        .onChange(of: appState.isAuthenticated) { _, authenticated in
            if !authenticated {
                assistantViewModel.clear()
                onboardingStatus = nil
                onboardingCheckState = .idle
            }
        }
        .onChange(of: appState.selectedTab) { _, selectedTab in
            showingGlobalActions = false
            UsageMonitor.screen(selectedTab)
        }
        .onDisappear {
            syncManager.stopAutoSync()
            Task { await FitnessSyncService.shared.pausePeriodicSync() }
        }
        .sheet(isPresented: $appState.showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $appState.showingFitnessOptIn) {
            FitnessWorkspaceOptInView()
        }
        .sheet(isPresented: $appState.showingDocumentCapture) {
            DocumentsView(
                startWithCapture: appState.sharedCaptureFileURL == nil,
                sharedFileURL: appState.sharedCaptureFileURL,
                onSharedCaptureCommitted: { appState.acknowledgeSharedCapture() }
            )
        }
        .sheet(isPresented: $appState.showingUniversalCapture) {
            UniversalCaptureView(
                initialText: appState.sharedCaptureText ?? "",
                onScanDocument: {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        appState.showingDocumentCapture = true
                    }
                },
                onContinueInBismarck: { text in
                    appState.assistantDraftText = text
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        appState.showingAssistantChat = true
                    }
                },
                onCaptureCommitted: { appState.acknowledgeSharedCapture() }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $appState.showingAddHub) {
            AddHubView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: appState.showingUniversalCapture) { _, showing in
            if !showing {
                appState.sharedCaptureText = nil
                appState.releaseSharedCapture()
            }
        }
        .onChange(of: appState.showingDocumentCapture) { _, showing in
            if !showing {
                appState.sharedCaptureFileURL = nil
                appState.releaseSharedCapture()
            }
        }
        .sheet(isPresented: $appState.showingAssistantChat) {
            ChatView(viewModel: assistantViewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingGlobalSearch) {
            GlobalSearchView()
        }
        .sheet(isPresented: $showingMoreDestinations) {
            MoreDestinationsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $onboardingStatus) { status in
            FirstFamilyOnboardingView(status: status) { _ in
                onboardingStatus = nil
                onboardingCheckState = .resolved
            }
        }
        .alert("Medicine reminder warning", isPresented: $syncManager.showMedicineSafetyWarning) {
            Button("Review medicine") {
                syncManager.acknowledgeMedicineSafetyWarnings()
                appState.openFamily(.medicine)
            }
            Button("Dismiss", role: .cancel) {
                syncManager.acknowledgeMedicineSafetyWarnings()
            }
        } message: {
            Text(
                "An offline dose was synced with a timing warning.\n\n"
                + syncManager.medicineSafetyWarnings.map(\.message).joined(separator: "\n")
            )
        }
    }

    @ViewBuilder
    private func customTabView(_ destination: CustomTabDestination) -> some View {
        switch destination {
        case .lists:
            LazyView(ListsTabView())
        case .house:
            LazyView(NavigationStack { HomeTab() })
        case .finance:
            LazyView(
                NavigationStack {
                    FinanceSimpleView(preferenceOwner: appState.currentUser?.id)
                }
            )
        case .fitness:
            LazyView(FitnessHubView())
        }
    }

    /// Avoids asking SwiftUI to dismiss a popover and present a sheet in the
    /// same update cycle. The short hand-off is imperceptible but reliable on
    /// both compact iPhones and regular-width iPads.
    private func presentAfterGlobalActionsDismiss(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        showingGlobalActions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                action()
            }
        }
    }

    private var onboardingRecoveryBanner: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                onboardingRecoveryLabel
                Spacer(minLength: 8)
                onboardingRetryButton
            }
            VStack(alignment: .leading, spacing: 4) {
                onboardingRecoveryLabel
                onboardingRetryButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
    }

    private var onboardingRecoveryLabel: some View {
        Label("Getting started could not be checked", systemImage: "person.example_35fbacff.circle.badge.exclamationmark")
            .font(.subheadline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var onboardingRetryButton: some View {
        Button {
            Task { await loadOnboardingIfNeeded() }
        } label: {
            Text("Try again")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .font(.subheadline.weight(.semibold))
    }

    @MainActor
    private func loadOnboardingIfNeeded() async {
        guard onboardingStatus == nil,
              appState.isAuthenticated,
              networkMonitor.isConnected,
              onboardingCheckState != .checking,
              onboardingCheckState != .resolved else { return }

        onboardingCheckState = .checking
        for attempt in 0..<2 {
            do {
                let status: OnboardingStatusDTO = try await APIClient.shared.get(
                    "/auth/onboarding",
                    bypassCache: true
                )
                onboardingCheckState = .resolved
                if status.shouldShow {
                    onboardingStatus = status
                }
                return
            } catch {
                guard !Task.isCancelled else {
                    onboardingCheckState = .idle
                    return
                }
                guard attempt == 0,
                      appState.isAuthenticated,
                      networkMonitor.isConnected else {
                    onboardingCheckState = .failed
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    onboardingCheckState = .idle
                    return
                }
            }
        }
    }
}

private struct FitnessWorkspaceOptInView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Fitness")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Plans, activities, recovery, nutrition and body records in one place.")
                    .foregroundStyle(.secondary)
                Label("Private to your account", systemImage: "lock.example_c6e20e62")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let error = appState.fitnessWorkspaceErrorMessage {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                Spacer(minLength: 12)

                Button {
                    Task { _ = await appState.enableFitnessAndOpen() }
                } label: {
                    if appState.isUpdatingFitnessWorkspace {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Text("Use Fitness").frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isUpdatingFitnessWorkspace)
                .accessibilityHint("Enables Fitness for your account and opens it")
            }
            .padding(24)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Fitness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .disabled(appState.isUpdatingFitnessWorkspace)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(appState.isUpdatingFitnessWorkspace)
    }
}

/// A compact, structural launcher in the app's bottom safe area. Family capture,
/// direct forms, search and secondary destinations stay one tap away; Fitness
/// keeps its scoped popover.
struct GlobalActionLauncher: View {
    @Binding var isPresented: Bool
    let isFitness: Bool
    let openCapture: () -> Void
    let openAdd: () -> Void
    let openSearch: () -> Void
    let openMore: () -> Void
    let openFitnessLog: () -> Void
    let openFitnessCoach: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if isFitness {
                    isPresented.toggle()
                    HapticManager.selection()
                } else {
                    openCapture()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isFitness ? "figure.run.circle.fill" : "text.bubble.fill")
                    Text(isFitness ? "Log or ask Coach" : "Tell HausKlar…")
                }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFitness ? "Log or ask Coach" : "Tell HausKlar")
            .accessibilityHint(isFitness ? "Open Fitness Log and Coach actions" : "Describe what needs adding, then review every change")
            .accessibilityIdentifier(isFitness ? "fitnessGlobalActionButton" : "globalActionButton")

            if !isFitness {
                shortcutButton(
                    label: "Add directly",
                    hint: "Open direct forms for events, tasks and family records",
                    systemImage: "plus",
                    identifier: "globalActionAddButton",
                    action: openAdd
                )
                shortcutButton(
                    label: "Find anything",
                    hint: "Search calendar, tasks, documents and family records",
                    systemImage: "magnifyingglass",
                    identifier: "globalActionSearchButton",
                    action: openSearch
                )
            }
            shortcutButton(
                label: "More destinations",
                hint: "Open unpinned destinations, tab bar choices and account settings",
                systemImage: "ellipsis",
                identifier: HausKlarAccessibilityID.Main.moreLauncher,
                action: openMore
            )
        }
        .frame(maxWidth: isFitness ? 320 : 360)
        .popover(
            isPresented: $isPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            GlobalActionLayer(
                close: { isPresented = false },
                openSearch: openSearch,
                openFitnessLog: openFitnessLog,
                openFitnessCoach: openFitnessCoach
            )
            .presentationCompactAdaptation(.popover)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func shortcutButton(
        label: LocalizedStringKey,
        hint: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

private struct MoreDestinationsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private var unpinnedDestinations: [CustomTabDestination] {
        appState.availableCustomTabDestinations.filter {
            !appState.tabBarSlots.contains($0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Tab bar") {
                    NavigationLink {
                        TabBarCustomizationView()
                    } label: {
                        rowLabel(
                            title: "Customise tab bar",
                            subtitle: "Choose the two destinations beside Today, Calendar and Family",
                            systemImage: "slider.horizontal.3",
                            showsChevron: false
                        )
                    }
                    .accessibilityIdentifier(HausKlarAccessibilityID.Main.moreCustomize)
                }

                if !unpinnedDestinations.isEmpty {
                    Section("More destinations") {
                        ForEach(unpinnedDestinations) { destination in
                            Button {
                                HapticManager.selection()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    appState.openCustomTab(destination)
                                }
                            } label: {
                                destinationButtonLabel(destination)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(accessibilityIdentifier(for: destination))
                        }
                    }
                }

                Section("Account") {
                    Button {
                        HapticManager.selection()
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            appState.showingSettings = true
                        }
                    } label: {
                        rowLabel(
                            title: "Settings and profile",
                            subtitle: "Account, notifications and connections",
                            systemImage: "person.example_35fbacff.circle",
                            showsChevron: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Main.moreSettings)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func destinationButtonLabel(_ destination: CustomTabDestination) -> some View {
        rowLabel(
            title: destination.title,
            subtitle: destination.subtitle,
            systemImage: destination.systemImage
        )
    }

    private func accessibilityIdentifier(for destination: CustomTabDestination) -> String {
        switch destination {
        case .lists: HausKlarAccessibilityID.Main.moreLists
        case .house: HausKlarAccessibilityID.Main.moreHouse
        case .finance: HausKlarAccessibilityID.Main.moreFinance
        case .fitness: HausKlarAccessibilityID.Main.moreFitness
        }
    }

    private func rowLabel(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct TabBarCustomizationView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var fourthTab: CustomTabDestination = .lists
    @State private var fifthTab: CustomTabDestination = .house
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section("Always shown") {
                fixedDestination("Today", systemImage: "calendar.badge.clock")
                fixedDestination("Calendar", systemImage: "calendar")
                fixedDestination(
                    "Family",
                    systemImage: "figure.2.and.child.holdinghands"
                )
            }

            Section {
                slotPicker("Fourth tab", selection: $fourthTab, excluding: fifthTab)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Main.tabSlotFour)
                slotPicker("Fifth tab", selection: $fifthTab, excluding: fourthTab)
                    .accessibilityIdentifier(HausKlarAccessibilityID.Main.tabSlotFive)
            } header: {
                Text("Choose two")
            } footer: {
                Text("You can still open every unpinned destination from More.")
            }
        }
        .navigationTitle("Customise tab bar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    appState.saveTabBarSlots([fourthTab, fifthTab])
                    dismiss()
                }
                .disabled(fourthTab == fifthTab)
                .accessibilityIdentifier(HausKlarAccessibilityID.Main.tabSave)
            }
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            if let first = appState.tabBarSlots.first { fourthTab = first }
            if appState.tabBarSlots.count > 1 { fifthTab = appState.tabBarSlots[1] }
        }
    }

    private func fixedDestination(
        _ title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "lock.example_c6e20e62")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Always shown")
        }
        .frame(minHeight: 44)
    }

    private func slotPicker(
        _ title: LocalizedStringKey,
        selection: Binding<CustomTabDestination>,
        excluding other: CustomTabDestination
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(appState.availableCustomTabDestinations.filter {
                $0 == selection.wrappedValue || $0 != other
            }) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
        }
        .frame(minHeight: 44)
    }
}

private struct GlobalActionLayer: View {
    let close: () -> Void
    let openSearch: () -> Void
    let openFitnessLog: () -> Void
    let openFitnessCoach: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fitness actions")
                        .font(.headline)
                        .accessibilityIdentifier("globalActionLayerTitle")
                    Text("Log something or talk it through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close quick actions")
                .accessibilityIdentifier("globalActionLayerClose")
            }

            VStack(spacing: 8) {
                actionButton(
                    "Find",
                    detail: "Calendar, tasks, documents and family records",
                    systemImage: "magnifyingglass",
                    identifier: "globalActionSearchButton",
                    action: openSearch
                )
                actionButton(
                    "Log",
                    detail: "Food, meals and nutrition",
                    systemImage: "fork.knife",
                    identifier: "globalActionFitnessLogButton",
                    action: openFitnessLog
                )
                actionButton(
                    "Coach",
                    detail: "Get help with training or nutrition",
                    systemImage: "bubble.left.and.text.bubble.right.fill",
                    identifier: "globalActionFitnessCoachButton",
                    action: openFitnessCoach
                )
            }
        }
        .padding(16)
        .frame(idealWidth: 320, maxWidth: 360)
        .accessibilityElement(children: .contain)
    }

    private func actionButton(
        _ title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
    }
}

enum AddHubDestination: String, Identifiable, CaseIterable {
    case event, task, shopping, medicine, nap, document, several
    var id: String { rawValue }
}

struct AddHubView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var destination: AddHubDestination?
    @State private var successMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let successMessage {
                    Section {
                        Label(successMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Section {
                    option("Event", subtitle: "Add something to the family calendar", icon: "calendar.badge.plus", color: .blue, destination: .event)
                    option("Task", subtitle: "Add a job or reminder", icon: "checkmark.circle", color: .indigo, destination: .task)
                    option("Shopping item", subtitle: "Put something straight on the Tesco list", icon: "cart.badge.plus", color: .orange, destination: .shopping)
                } header: {
                    Text("Everyday")
                }

                Section {
                    option("Record medicine", subtitle: "Use the parent-entered reminder logger", icon: "cross.case.fill", color: .blue, destination: .medicine)
                    option("Start nap", subtitle: "Start a child's nap timer", icon: "moon.zzz.fill", color: .purple, destination: .nap)
                    option("Letter or file", subtitle: "Scan, photograph or choose a document", icon: "doc.viewfinder", color: .teal, destination: .document)
                } header: {
                    Text("Family")
                }

                Section {
                    option("Several events or tasks", subtitle: "Paste a message and review every item", icon: "text.badge.plus", color: .green, destination: .several)
                } header: {
                    Text("Several things")
                }

                Section {
                    Label("Medicine compares saved entries with timing and count limits entered by the parent. It does not recommend dosage, and Bismarck cannot log a dose.", systemImage: "shield.checkered")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $destination) { choice in
                destinationView(choice)
            }
        }
    }

    private func option(
        _ title: String,
        subtitle: String,
        icon: String,
        color: Color,
        destination: AddHubDestination
    ) -> some View {
        Button {
            self.destination = destination
            HapticManager.selection()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 32, height: 32)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    @ViewBuilder
    private func destinationView(_ choice: AddHubDestination) -> some View {
        switch choice {
        case .event:
            QuickEventSheet(initialDate: Date()) {
                successMessage = "Event added to Calendar."
            }
        case .task:
            QuickTaskSheet(initialDate: Date()) {
                successMessage = "Task added to Tasks."
            }
        case .shopping:
            QuickShoppingItemSheet {
                successMessage = "Item added to Shopping."
            }
        case .medicine:
            NavigationStack { MedicineView(startWithLogDose: true) }
        case .nap:
            NavigationStack { NapsView(startWithNap: true) }
        case .document:
            DocumentsView(startWithCapture: true)
        case .several:
            UniversalCaptureView(
                onScanDocument: { destination = .document },
                onContinueInBismarck: { text in
                    appState.assistantDraftText = text
                    destination = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { dismiss() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                        appState.showingAssistantChat = true
                    }
                }
            )
        }
    }
}

private struct CreateShoppingItemRequest: Encodable {
    let id: String
    let name: String
    let quantity: String?
    let category: String?
    let clientId: String
    let clientTimestamp: String
}

private struct QuickShoppingItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var quantity = ""
    @State private var category = ""
    @State private var isSaving = false
    @State private var savedName: String?
    @State private var errorMessage: String?
    let onSaved: () -> Void

    init(onSaved: @escaping () -> Void = {}) {
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Group {
                if let savedName {
                    VStack(spacing: 20) {
                        Spacer()
                        ContentUnavailableView(
                            "Added to Shopping",
                            systemImage: "checkmark.circle.fill",
                            description: Text("\(savedName) is ready on the Tesco list.")
                        )
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding()
                } else {
                    Form {
                        Section("Shopping item") {
                            TextField("Item", text: $name)
                                .textInputAutocapitalization(.sentences)
                            TextField("Quantity (optional)", text: $quantity)
                            TextField("Category (optional)", text: $category)
                        }
                        if let errorMessage {
                            Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                        }
                    }
                }
            }
            .navigationTitle("Add Shopping Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if savedName == nil { Button("Cancel") { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if savedName == nil {
                        Button(isSaving ? "Adding…" : "Add") { save() }
                            .disabled(
                                isSaving
                                    || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.medium])
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let _: ShoppingItemDTO = try await APIClient.shared.post(
                    "/meals/shopping",
                    body: CreateShoppingItemRequest(
                        id: UUID().uuidString,
                        name: cleanName,
                        quantity: nilIfEmpty(quantity),
                        category: nilIfEmpty(category),
                        clientId: try APIClient.shared.clientId,
                        clientTimestamp: ISODateParser.string(from: Date())
                    )
                )
                savedName = cleanName
                onSaved()
                NotificationCenter.default.post(name: .shoppingDataChanged, object: nil)
                HapticManager.success()
            } catch APIError.offlineQueued {
                savedName = cleanName
                onSaved()
                NotificationCenter.default.post(name: .shoppingDataChanged, object: nil)
                HapticManager.success()
            } catch let error as APIError {
                errorMessage = error.errorDescription
                HapticManager.error()
            } catch let error as ClientIdentityError {
                errorMessage = error.errorDescription
                HapticManager.error()
            } catch {
                errorMessage = "The item could not be added. Please try again."
                HapticManager.error()
            }
            isSaving = false
        }
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A people-first family home. Each child leads with what matters now; deeper records
/// stay close at hand without competing with the daily care picture.
struct FamilyTabView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var summaryVM = ChildrenSummaryViewModel()
    @State private var childChooser: ChildDTO?
    @State private var avatarCrop: AvatarCropSelection?
    @State private var avatarPickerError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    if summaryVM.isLoading && summaryVM.children.isEmpty {
                        familyLoadingState
                    } else if let errorMessage = summaryVM.errorMessage, summaryVM.children.isEmpty {
                        ContentUnavailableView {
                            Label("Family is unavailable", systemImage: "person.example_81b06587")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("Try again") { Task { await summaryVM.loadSummary() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                    } else {
                        familyToday
                        parents
                    }
                    householdTools
                }
                .padding()
            }
            .navigationTitle("Family")
            .task {
                await summaryVM.loadSummary()
                openPreferredProfileIfNeeded()
            }
            .onChange(of: appState.preferredFamilyProfileRequestId) { _, _ in
                openPreferredProfileIfNeeded()
            }
            .refreshable {
                await summaryVM.loadSummary()
            }
            .navigationDestination(item: $appState.familyRoute) { route in
                switch route {
                case .documents: DocumentsView(initialPersonId: appState.preferredFamilyChildId, initialDocumentId: appState.highlightedDocumentResultId)
                case .starCharts:
                    StarChartView(
                        initialChildId: appState.preferredFamilyChildId,
                        initialChartId: appState.preferredStarChartId
                    )
                case .medicine:
                    MedicineView(
                        initialChildId: appState.preferredFamilyChildId,
                        initialMedicineTypeId: appState.preferredMedicineTypeId,
                        reviewRequestId: appState.medicineReviewRequestId
                    )
                case .naps:
                    NapsView(
                        initialChildId: appState.preferredFamilyChildId,
                        initialNapId: appState.preferredNapId
                    )
                case .illness: IllnessDetailView(initialChildId: appState.preferredFamilyChildId)
                case .homework:
                    HomeworkView(
                        initialChildId: appState.preferredFamilyChildId,
                        initialSpellingsId: appState.preferredHomeworkItemId,
                        initialReadingId: appState.preferredReadingItemId
                    )
                case .growth: GrowthView(initialChildId: appState.preferredFamilyChildId)
                case .presents:
                    PresentsView(
                        initialChildId: appState.preferredFamilyChildId,
                        initialIdeaId: appState.preferredPresentItemId
                    )
                case .dog: DogView()
                case .artwork: ArtworkGalleryView(initialChildId: appState.preferredFamilyChildId, initialArtworkId: appState.highlightedArtworkResultId)
                case .yearbook: YearbookView(initialChildId: appState.preferredFamilyChildId)
                case .health:
                    HealthRecordView(
                        initialChildId: appState.preferredFamilyChildId,
                        initialVaccinationKey: appState.preferredVaccinationKey
                    )
                case .fitness: FitnessHubView()
                case .house: HomeTab()
                case .photos: PhotosGalleryView(initialChildId: appState.preferredFamilyChildId, initialPhotoId: appState.highlightedPhotoResultId)
                case .birthdays: BirthdaysView(initialBirthdayId: appState.highlightedBirthdayResultId)
                case .caregiver: BabysitterModeView()
                }
            }
            .sheet(item: $childChooser) { child in
                NavigationStack {
                    List {
                        Section("Care") {
                            childModuleRow("Medicine", icon: "cross.case.fill", route: .medicine, child: child)
                            childModuleRow("Sleep", icon: "moon.fill", route: .naps, child: child)
                            childModuleRow("Illness", icon: "thermometer.high", route: .illness, child: child)
                        }
                        Section("School") {
                            childModuleRow("Star Charts", icon: "star.fill", route: .starCharts, child: child)
                            childModuleRow("Homework", icon: "book.fill", route: .homework, child: child)
                        }
                        Section("Memories") {
                            childModuleRow("Artwork", icon: "paintpalette.fill", route: .artwork, child: child)
                            childModuleRow("Photos", icon: "photo.stack.fill", route: .photos, child: child)
                            childModuleRow("Yearbook", icon: "book.closed.fill", route: .yearbook, child: child)
                        }
                        Section("Records") {
                            childModuleRow("Documents", icon: "doc.text.fill", route: .documents, child: child)
                            childModuleRow("Health", icon: "heart.text.square.fill", route: .health, child: child)
                            childModuleRow("Growth", icon: "chart.line.uptrend.xyaxis", route: .growth, child: child)
                        }
                    }
                    .navigationTitle(child.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { childChooser = nil } } }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $avatarCrop) { selection in
                PersonAvatarCropView(selection: selection) { data in
                    try await summaryVM.uploadAvatar(data, for: selection.member)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func openPreferredProfileIfNeeded() {
        guard appState.preferredFamilyProfileRequestId != nil,
              let childId = appState.preferredFamilyChildId,
              let child = summaryVM.children.first(where: { $0.id == childId }) else { return }
        childChooser = child
        appState.preferredFamilyProfileRequestId = nil
    }

    @ViewBuilder
    private var familyToday: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Today by person")
                    .font(.title2.weight(.bold))
                Text("Care, plans and the next useful thing — together.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let summaryMessage = summaryVM.summaryMessage {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(summaryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Try again") { Task { await summaryVM.loadSummary() } }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            }

            if summaryVM.children.isEmpty {
                ContentUnavailableView {
                    Label("No children yet", systemImage: "person.example_35fbacff.circle.badge.plus")
                } description: {
                    Text("Children added to your family will appear here.")
                }
                .frame(maxWidth: .infinity)
            } else {
                ForEach(summaryVM.children) { child in
                    childTodayCard(child)
                }
            }

            if let avatarPickerError {
                Text(avatarPickerError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("avatarPickerError")
            }
        }
    }

    private var familyLoadingState: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView("Opening family…")
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Circle().fill(Color.secondary.opacity(0.16)).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 7) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.16)).frame(width: 110, height: 17)
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)).frame(height: 12)
                        }
                    }
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)).frame(height: 38)
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)).frame(height: 70)
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            }
        }
    }

    private func childTodayCard(_ child: ChildDTO) -> some View {
        let care = summaryVM.careState(for: child.id)
        let plans = summaryVM.todayItems(for: child.id)
        let chart = summaryVM.activeChart(for: child.id)
        let action = summaryVM.nextAction(for: child.id)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let member = summaryVM.member(for: child.id) {
                    PersonAvatarPicker(
                        member: member,
                        isSaving: summaryVM.avatarSavingId == member.id,
                        onPicked: {
                            avatarPickerError = nil
                            avatarCrop = $0
                        },
                        onError: { avatarPickerError = $0 }
                    )
                } else {
                    Image(systemName: "person.example_35fbacff.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                }

                Button { childChooser = child } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(child.name)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)
                            Text("Open care, school, memories and records")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(child.name)'s family page")
            }

            Divider()

            if !care.isQuiet {
                Label(care.text, systemImage: care.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(care.color)
            }

            if !summaryVM.todayAvailable || !plans.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Today", systemImage: "calendar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !summaryVM.todayAvailable {
                        Text("Today's plans could not be loaded.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(plans.prefix(2)), id: \.self) { title in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Circle().fill(Color.secondary.opacity(0.55)).frame(width: 4, height: 4)
                                Text(title).font(.subheadline).lineLimit(1)
                            }
                        }
                        if plans.count > 2 {
                            Text("+\(plans.count - 2) more today")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let chart {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label(chart.title, systemImage: "star.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(chart.starsCount) of \(chart.totalCells)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(chart.starsCount), total: Double(max(chart.totalCells, 1)))
                        .tint(.yellow)
                        .accessibilityLabel("\(chart.title) star progress")
                        .accessibilityValue("\(chart.starsCount) of \(chart.totalCells) stars")
                }
            }

            Button {
                if let route = action.route {
                    openModule(route, childId: child.id)
                } else {
                    childChooser = child
                }
            } label: {
                Label(action.label, systemImage: action.icon)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Keeps \(child.name) selected")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private var parents: some View {
        let adults = summaryVM.familyMembers.filter { $0.memberType == "user" }
        if !adults.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Parents")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(adults) { member in
                    HStack(spacing: 10) {
                        PersonAvatarPicker(
                            member: member,
                            isSaving: summaryVM.avatarSavingId == member.id,
                            onPicked: {
                                avatarPickerError = nil
                                avatarCrop = $0
                            },
                            onError: { avatarPickerError = $0 }
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name).font(.subheadline.weight(.semibold))
                            Text("Parent").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var householdTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Household")
                .font(.headline)
                .foregroundStyle(.secondary)
            householdRow("Letters & documents", subtitle: "Paperwork and its follow-up", icon: "tray.full.fill", route: .documents)
            householdRow("House", subtitle: "Lights, heating and home controls", icon: "house.fill", route: .house)
            householdRow("Dog", subtitle: "Walks, meals and care", icon: "pawprint.fill", route: .dog)
            householdRow("Presents", subtitle: "Ideas for birthdays and Christmas", icon: "gift.fill", route: .presents)
            householdRow("Babysitter handover", subtitle: "Prepare and share time-limited care details", icon: "person.example_4163b177.key", route: .caregiver)
        }
    }

    private func householdRow(_ title: String, subtitle: String, icon: String, route: FamilyRoute) -> some View {
        Button {
            openModule(route)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openModule(_ route: FamilyRoute, childId: String? = nil) {
        if route == .fitness {
            appState.openFitness(destination: .overview)
            return
        }
        appState.openFamily(route, childId: childId)
    }

    private func childModuleRow(_ title: String, icon: String, route: FamilyRoute, child: ChildDTO) -> some View {
        Button {
            childChooser = nil
            openModule(route, childId: child.id)
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }
}

struct ListsTabView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Get things done") {
                    listRow("Tasks", subtitle: "Today, upcoming and household jobs", icon: "checklist", color: .blue, route: .tasks)
                    listRow("Meals & Shopping", subtitle: "Plan meals, shop and manage the pantry", icon: "fork.knife", color: .orange, route: .meals)
                }

                Section("Stay ahead") {
                    listRow("Renewals", subtitle: "Passport, MOT, insurance — never get caught out", icon: "bell.badge", color: .purple, route: .renewals)
                }

                Section("Plan ahead") {
                    listRow("Routines & school dates", subtitle: "Maintain recurring school and family commitments", icon: "repeat.circle", color: .green, route: .routines)
                    listRow("Packing lists", subtitle: "Checklists offered before swimming, PE and other events", icon: "backpack.fill", color: .teal, route: .prepPacks)
                }
            }
            .navigationTitle("Lists")
            .navigationDestination(item: $appState.listsRoute) { route in
                switch route {
                case .tasks: TasksView()
                case .meals: MealsView(initialTab: appState.preferredMealsSection ?? 0)
                case .routines: RoutineView()
                case .renewals: RenewalsView()
                case .prepPacks: PrepPacksView()
                }
            }
        }
    }

    private func listRow(
        _ title: String,
        subtitle: String,
        icon: String,
        color: Color,
        route: ListsRoute
    ) -> some View {
        Button {
            appState.listsRoute = route
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class PrepPacksViewModel: ObservableObject {
    @Published var templates: [PrepPackTemplateDTO] = []
    @Published var members: [FamilyMemberDTO] = []
    @Published var isLoading = false
    @Published var busyId: String?
    @Published var errorMessage: String?
    private let api = APIClient.shared

    func load() async {
        isLoading = true
        errorMessage = nil
        async let packs: [PrepPackTemplateDTO] = api.get("/prep-packs/templates", bypassCache: true)
        async let people: [FamilyMemberDTO] = api.get("/family/members")
        do {
            let (loadedPacks, loadedPeople) = try await (packs, people)
            templates = loadedPacks
            members = loadedPeople.filter { $0.memberType == "user" }
        } catch {
            errorMessage = "Preparation packs could not be loaded.".localized
        }
        isLoading = false
    }

    func save(_ draft: PrepPackDraft) async -> Bool {
        busyId = draft.id ?? "new"
        errorMessage = nil
        defer { busyId = nil }
        let request = PrepPackTemplateRequest(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            matchTerms: draft.matchTerms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            items: draft.items.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            leadHours: draft.leadHours,
            assignedTo: draft.assignedTo.isEmpty ? nil : draft.assignedTo
        )
        guard !request.name.isEmpty, !request.matchTerms.isEmpty, !request.items.isEmpty else {
            errorMessage = "Add a name, a matching phrase and at least one checklist item.".localized
            return false
        }
        do {
            let saved: PrepPackTemplateDTO
            if let id = draft.id {
                saved = try await api.patch("/prep-packs/templates/\(id)", body: request)
            } else {
                saved = try await api.post("/prep-packs/templates", body: request)
            }
            templates.removeAll { $0.id == saved.id }
            templates.append(saved)
            templates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            HapticManager.success()
            return true
        } catch {
            errorMessage = "That preparation pack could not be saved.".localized
            HapticManager.error()
            return false
        }
    }

    func toggle(_ template: PrepPackTemplateDTO) async {
        busyId = template.id
        defer { busyId = nil }
        do {
            let updated: PrepPackTemplateDTO = try await api.patch(
                "/prep-packs/templates/\(template.id)", body: PrepPackEnabledRequest(enabled: !template.enabled)
            )
            if let index = templates.firstIndex(where: { $0.id == updated.id }) { templates[index] = updated }
            HapticManager.selection()
        } catch { errorMessage = "That preparation pack could not be updated.".localized }
    }

    func remove(_ template: PrepPackTemplateDTO) async {
        busyId = template.id
        defer { busyId = nil }
        do {
            try await api.delete("/prep-packs/templates/\(template.id)")
            templates.removeAll { $0.id == template.id }
            HapticManager.success()
        } catch { errorMessage = "That preparation pack could not be removed.".localized }
    }
}

private struct PrepPackDraft: Identifiable {
    let id: String?
    var name: String
    var matchTerms: String
    var items: String
    var leadHours: Int
    var assignedTo: String

    init(_ template: PrepPackTemplateDTO? = nil) {
        id = template?.id
        name = template?.name ?? ""
        matchTerms = template?.matchTerms.joined(separator: ", ") ?? ""
        items = template?.items.joined(separator: "\n") ?? ""
        leadHours = template?.leadHours ?? 24
        assignedTo = template?.assignedTo ?? ""
    }
}

private struct PrepPacksView: View {
    @StateObject private var viewModel = PrepPacksViewModel()
    @State private var editing: PrepPackDraft?
    @State private var removing: PrepPackTemplateDTO?

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.templates.isEmpty {
                ProgressView("Loading preparation packs…")
            } else if viewModel.templates.isEmpty {
                ContentUnavailableView("No preparation packs", systemImage: "backpack", description: Text("Add an activity and HausKlar will offer its checklist before matching events."))
            } else {
                List(viewModel.templates) { template in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(template.name, systemImage: "backpack.fill").font(.headline)
                            Spacer()
                            if !template.enabled { Text("PAUSED").font(.caption2.bold()).foregroundStyle(.secondary) }
                        }
                        Text("Matches \(template.matchTerms.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(template.items, id: \.self) { Label($0, systemImage: "checkmark").font(.subheadline) }
                        HStack {
                            Button("Edit") { editing = PrepPackDraft(template) }.buttonStyle(.bordered)
                            Button(template.enabled ? "Pause" : "Enable") { Task { await viewModel.toggle(template) } }.buttonStyle(.bordered)
                            Button("Remove", role: .destructive) { removing = template }.buttonStyle(.bordered)
                        }
                        .disabled(viewModel.busyId != nil)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("Packing lists")
        .toolbar { Button { editing = PrepPackDraft() } label: { Label("Add pack", systemImage: "plus") } }
        .task { await viewModel.load() }
        .refreshable { await viewModel.load() }
        .sheet(item: $editing) { draft in PrepPackEditor(draft: draft, members: viewModel.members) { updated in
            if await viewModel.save(updated) { editing = nil }
        } }
        .alert("Remove preparation pack?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let item = removing { Task { await viewModel.remove(item); removing = nil } } }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Future matching events will no longer offer this checklist.") }
        .alert("Something went wrong", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: { Text(viewModel.errorMessage ?? "") }
    }
}

private struct PrepPackEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: PrepPackDraft
    let members: [FamilyMemberDTO]
    let onSave: (PrepPackDraft) async -> Void
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity") {
                    TextField("Swimming", text: $draft.name)
                    TextField("Calendar title contains", text: $draft.matchTerms)
                    Text("Separate alternatives with commas, such as swimming, swim lesson.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Checklist — one task per line") { TextEditor(text: $draft.items).frame(minHeight: 120) }
                Section("Timing and owner") {
                    Picker("Offer pack", selection: $draft.leadHours) {
                        Text("At event time").tag(0); Text("12 hours before").tag(12); Text("1 day before").tag(24); Text("2 days before").tag(48); Text("3 days before").tag(72)
                    }
                    Picker("Usually assign to", selection: $draft.assignedTo) {
                        Text("Nobody yet").tag("")
                        ForEach(members) { Text($0.name).tag($0.id) }
                    }
                }
            }
            .navigationTitle(draft.id == nil ? "Add Pack" : "Edit Pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button(saving ? "Saving…" : "Save") { saving = true; Task { await onSave(draft); saving = false } }.disabled(saving) }
            }
        }
    }
}

struct FamilyChildCareState {
    let text: String
    let icon: String
    let color: Color
    let isQuiet: Bool
}

struct FamilyChildNextAction {
    let label: String
    let icon: String
    let route: FamilyRoute?
}

/// Builds a small, deterministic daily picture for each child from the same
/// snapshot used by Today, plus active star-chart progress.
@MainActor
final class ChildrenSummaryViewModel: ObservableObject {
    @Published var activeNaps: [NapDTO] = []
    @Published var activeIllnesses: [ActiveIllnessDTO] = []
    @Published var routines: [ActiveRoutineDTO] = []
    @Published var events: [CalendarEventDTO] = []
    @Published var medicine: [GlanceMedicineDTO] = []
    @Published var starCharts: [StarChartDTO] = []
    @Published var children: [ChildDTO] = []
    @Published var familyMembers: [FamilyMemberDTO] = []
    @Published var avatarSavingId: String?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var summaryMessage: String?
    @Published var todayAvailable = false
    @Published var starProgressAvailable = false

    private let apiClient = APIClient.shared

    func loadSummary() async {
        isLoading = true
        errorMessage = nil
        summaryMessage = nil
        defer { isLoading = false }

        async let childrenResult = fetchChildren()
        async let membersResult = fetchFamilyMembers()
        async let dashboardResult = fetchDashboard()
        async let chartsResult = fetchActiveCharts()

        let (fetchedChildren, fetchedMembers, dashboard, fetchedCharts) = await (
            childrenResult,
            membersResult,
            dashboardResult,
            chartsResult
        )

        var someDetailsUnavailable = false

        if let fetchedChildren {
            children = fetchedChildren
        } else if children.isEmpty {
            errorMessage = "Your family could not be opened. Please try again."
        } else {
            someDetailsUnavailable = true
        }

        if let dashboard {
            activeNaps = dashboard.naps
            activeIllnesses = dashboard.illnesses
            routines = dashboard.routines
            events = dashboard.events
            medicine = dashboard.medicine
            let dailySummaryKeys: Set<String> = ["events", "naps", "illnesses", "routines", "medicine"]
            todayAvailable = dailySummaryKeys.isDisjoint(with: dashboard.unavailable)
            let familySummaryKeys = dailySummaryKeys.union(["family_members"])
            if !familySummaryKeys.isDisjoint(with: dashboard.unavailable) {
                someDetailsUnavailable = true
            }
            if fetchedMembers == nil {
                familyMembers = dashboard.familyMembers
            }
        } else {
            todayAvailable = false
            someDetailsUnavailable = true
        }

        if let fetchedMembers {
            familyMembers = fetchedMembers
        } else if familyMembers.isEmpty {
            someDetailsUnavailable = true
        }

        if let fetchedCharts {
            starProgressAvailable = true
            starCharts = fetchedCharts
        } else {
            starProgressAvailable = false
            someDetailsUnavailable = true
        }

        if someDetailsUnavailable && errorMessage == nil {
            summaryMessage = "A few details for today could not be loaded."
        }
    }

    func uploadAvatar(_ data: Data, for member: FamilyMemberDTO) async throws {
        avatarSavingId = member.id
        defer { avatarSavingId = nil }
        do {
            let updated: FamilyMemberDTO = try await apiClient.uploadMultipartFiles(
                "/family/members/\(member.id)/avatar",
                fileFieldName: "file",
                files: [(filename: "avatar.jpg", mediaType: "image/jpeg", data: data)],
                orderedFields: [],
                method: "PUT"
            )
            if let index = familyMembers.firstIndex(where: { $0.id == updated.id }) {
                familyMembers[index] = updated
            }
        } catch APIError.offlineQueued {
            return
        }
    }

    func member(for childId: String) -> FamilyMemberDTO? {
        familyMembers.first { $0.id == childId }
    }

    func careState(for childId: String) -> FamilyChildCareState {
        guard todayAvailable else {
            return FamilyChildCareState(
                text: "Today's care could not be loaded",
                icon: "arrow.clockwise",
                color: .secondary,
                isQuiet: false
            )
        }
        if let nap = activeNaps.first(where: { $0.childId == childId }),
           let startedAt = ISODateParser.parse(nap.startedAt) {
            return FamilyChildCareState(
                text: "Sleeping since \(ISODateParser.timeOnly(from: startedAt))",
                icon: "moon.zzz.fill",
                color: .purple,
                isQuiet: false
            )
        }
        if activeIllnesses.contains(where: { $0.childId == childId }) {
            return FamilyChildCareState(
                text: "Illness mode is active",
                icon: "thermometer.high",
                color: .red,
                isQuiet: false
            )
        }
        if let item = medicine.first(where: { $0.childId == childId }) {
            if item.isSafeNow {
                return FamilyChildCareState(
                    text: "\(item.medicineName) can be recorded now",
                    icon: "cross.case.fill",
                    color: .blue,
                    isQuiet: false
                )
            }
            if let nextSafeAt = item.nextSafeAt.flatMap(ISODateParser.parse) {
                return FamilyChildCareState(
                    text: "\(item.medicineName) from \(ISODateParser.timeOnly(from: nextSafeAt))",
                    icon: "cross.case.fill",
                    color: .blue,
                    isQuiet: false
                )
            }
        }
        return FamilyChildCareState(
            text: "Care is quiet",
            icon: "checkmark.circle.fill",
            color: .secondary,
            isQuiet: true
        )
    }

    func todayItems(for childId: String) -> [String] {
        let routineNames = routines
            .filter { $0.personId == childId }
            .map(\.name)
        let eventNames = events
            .filter { event in
                event.assignedTo == childId
                    || event.familyMemberIds?.contains(childId) == true
                    || event.affectedMemberIds?.contains(childId) == true
            }
            .map(\.title)

        var seen = Set<String>()
        return (routineNames + eventNames).filter { seen.insert($0).inserted }
    }

    func activeChart(for childId: String) -> StarChartDTO? {
        guard starProgressAvailable else { return nil }
        return starCharts.first { $0.childId == childId && $0.completedAt == nil }
    }

    func nextAction(for childId: String) -> FamilyChildNextAction {
        if todayAvailable && activeNaps.contains(where: { $0.childId == childId }) {
            return FamilyChildNextAction(label: "Open sleep", icon: "moon.fill", route: .naps)
        }
        if todayAvailable && activeIllnesses.contains(where: { $0.childId == childId }) {
            return FamilyChildNextAction(label: "Open illness mode", icon: "thermometer.high", route: .illness)
        }
        if todayAvailable && medicine.contains(where: { $0.childId == childId && $0.isSafeNow }) {
            return FamilyChildNextAction(label: "Record medicine", icon: "cross.case.fill", route: .medicine)
        }
        if activeChart(for: childId) != nil {
            return FamilyChildNextAction(label: "Award a star", icon: "star.fill", route: .starCharts)
        }
        let name = children.first { $0.id == childId }?.name ?? "child"
        return FamilyChildNextAction(label: "Open \(name)'s page", icon: "person.example_35fbacff.circle", route: nil)
    }

    private func fetchChildren() async -> [ChildDTO]? {
        do {
            return try await apiClient.get("/children/")
        } catch {
            return nil
        }
    }

    private func fetchFamilyMembers() async -> [FamilyMemberDTO]? {
        do {
            return try await apiClient.get("/family/members", bypassCache: true)
        } catch {
            return nil
        }
    }

    private func fetchDashboard() async -> TodayDashboardDTO? {
        do {
            return try await apiClient.get(
                "/briefing/dashboard",
                queryItems: [URLQueryItem(name: "timezone", value: TimeZone.current.identifier)],
                bypassCache: true
            )
        } catch {
            return nil
        }
    }

    private func fetchActiveCharts() async -> [StarChartDTO]? {
        do {
            return try await apiClient.get(
                "/star-charts/",
                queryItems: [
                    URLQueryItem(name: "active", value: "true"),
                    URLQueryItem(name: "limit", value: "200"),
                ]
            )
        } catch {
            return nil
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AppState())
        .environmentObject(NetworkMonitor())
}
