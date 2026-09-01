import Foundation
import SwiftUI
import SwiftData
import LocalAuthentication
import os

enum LocalIdentityBoundaryError: LocalizedError {
    case storeNotConfigured
    case transitionInProgress

    var errorDescription: String? {
        switch self {
        case .storeNotConfigured:
            "HausKlar could not secure local family data. Restart the app and try again."
        case .transitionInProgress:
            "HausKlar is still securing local family data. Please wait a moment."
        }
    }
}

/// One fail-closed erasure path for manual logout, account changes and account
/// deletion. Auth expiry uses a non-destructive lock so owner-bound offline work
/// can resume after the same account authenticates again.
enum LocalIdentityDataPurger {
    static func hasAnyRecords(_ modelContext: ModelContext) throws -> Bool {
        try modelContext.fetchCount(FetchDescriptor<OfflineAction>()) > 0
            || modelContext.fetchCount(FetchDescriptor<PendingDocumentUpload>()) > 0
            || modelContext.fetchCount(FetchDescriptor<CalendarEvent>()) > 0
            || modelContext.fetchCount(FetchDescriptor<FamilyTask>()) > 0
    }

    static func purgeRecords(_ modelContext: ModelContext) throws {
        try modelContext.delete(model: PendingDocumentUpload.self)
        try modelContext.delete(model: OfflineAction.self)
        try modelContext.delete(model: CalendarEvent.self)
        try modelContext.delete(model: FamilyTask.self)
        try modelContext.delete(model: Child.self)
        try modelContext.delete(model: MedicineType.self)
        try modelContext.delete(model: MedicineDose.self)
        try modelContext.delete(model: Nap.self)
        try modelContext.delete(model: DogActivity.self)
        try modelContext.delete(model: Birthday.self)
        try modelContext.delete(model: Meal.self)
        try modelContext.delete(model: MealPlan.self)
        try modelContext.delete(model: ShoppingItem.self)
        try modelContext.delete(model: HealthRecord.self)
        try modelContext.delete(model: ReadingLog.self)
        try modelContext.delete(model: SpellingEntry.self)
        try modelContext.delete(model: GrowthRecord.self)
        try modelContext.delete(model: RoutineItem.self)
        try modelContext.save()
    }

    @MainActor
    static func purgeAll(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard
    ) async throws {
        let fitnessIdentity = defaults.string(forKey: AppState.localOwnerKey)
        // Remove durable plaintext/protected copies before deleting their queue rows,
        // so any filesystem failure remains retryable and blocks the next identity.
        try DocumentCaptureService.purgePendingUploadsSecurely()
        try SharedCaptureStore.purge()
        try GlanceStore.clear()
        AmbientIntentRouteStore.clear()
        try await HomeSnapshotStore.shared.securePurge()
        try await FileCache.shared.securePurge()
        try await SchoolTimetableStaging.purgeAll()
        try await ShareExportStore.shared.securePurgeAll()
        DecodedImageCache.shared.suspend()
        try LocalStoreRecovery.purgeArchives()
        if let fitnessIdentity {
            try FitnessDatabase.shared.deleteStore(
                identity: fitnessIdentity,
                legacyOwnerProof: fitnessIdentity
            )
            try FitnessPendingFITInbox.purgeOwned(identity: fitnessIdentity)
        }
        try purgeRecords(modelContext)

        DocumentCaptureService.purgeTemporaryCaptures()
        DocumentPreviewStore.purgeAll()
        HAClient.shared.reset()
        SearchResultCache.shared.clear()
        ScheduleAutomationService.shared.resetDismissals()
        MedicineActivityManager.shared.endAll()
        NapActivityManager.shared.endAll()
        OwnerScopedPreferences.purge(identity: fitnessIdentity, defaults: defaults)
    }
}

/// Represents the authenticated user profile.
struct UserProfile: Codable, Equatable {
    let id: String
    let name: String
    let email: String
    let role: String
    let priority: Int
    let familyId: String?
    var mustChangePassword: Bool?
}

/// Stable top-level destinations. Today, Calendar and Family are permanent;
/// the remaining two visible slots are chosen by the signed-in adult.
enum AppTab: String, Codable, Hashable {
    case today, calendar, family, lists, house, finance, fitness
}

enum CustomTabDestination: String, Codable, Identifiable, CaseIterable {
    case lists
    case house
    case finance
    case fitness

    var id: String { rawValue }

    var appTab: AppTab {
        switch self {
        case .lists: .lists
        case .house: .house
        case .finance: .finance
        case .fitness: .fitness
        }
    }

    init?(appTab: AppTab) {
        switch appTab {
        case .lists: self = .lists
        case .house: self = .house
        case .finance: self = .finance
        case .fitness: self = .fitness
        case .today, .calendar, .family: return nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .lists: "Lists"
        case .house: "House"
        case .finance: "Finance"
        case .fitness: "Fitness"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .lists: "Tasks, meals and household jobs"
        case .house: "Lights, heating and home controls"
        case .finance: "Balances, spending and plans for the money you can see"
        case .fitness: "Your private training and health workspace"
        }
    }

    var systemImage: String {
        switch self {
        case .lists: "checklist"
        case .house: "house.fill"
        case .finance: "sterlingsign.circle.fill"
        case .fitness: "figure.run"
        }
    }
}

enum TabBarPreferencePolicy {
    static let slotCount = 2

    static func available(
        hasFamilyAccount: Bool,
        fitnessEnabled: Bool
    ) -> [CustomTabDestination] {
        var result: [CustomTabDestination] = [.lists, .house]
        if hasFamilyAccount { result.append(.finance) }
        if fitnessEnabled { result.append(.fitness) }
        return result
    }

    static func resolve(
        saved: [CustomTabDestination]?,
        hasFamilyAccount: Bool,
        fitnessEnabled: Bool,
        fitnessPinned: Bool
    ) -> [CustomTabDestination] {
        let available = available(
            hasFamilyAccount: hasFamilyAccount,
            fitnessEnabled: fitnessEnabled
        )
        let defaultOrder: [CustomTabDestination] = fitnessEnabled && fitnessPinned
            ? [.lists, .fitness, .house, .finance]
            : [.lists, .house, .finance, .fitness]
        var result: [CustomTabDestination] = []
        for destination in (saved ?? defaultOrder) + defaultOrder + available
        where available.contains(destination) && !result.contains(destination) {
            result.append(destination)
            if result.count == slotCount { break }
        }
        return result
    }

    static func visible(
        preferred: [CustomTabDestination],
        selectedTab: AppTab,
        available: [CustomTabDestination]
    ) -> [CustomTabDestination] {
        var visible: [CustomTabDestination] = []
        for destination in preferred + available
        where available.contains(destination) && !visible.contains(destination) {
            visible.append(destination)
            if visible.count == slotCount { break }
        }
        guard let selected = CustomTabDestination(appTab: selectedTab),
              available.contains(selected),
              !visible.contains(selected)
        else { return visible }
        visible = Array(visible.prefix(max(0, slotCount - 1)))
        visible.append(selected)
        return visible
    }
}

enum FamilyRoute: String, Identifiable, Hashable {
    case documents, starCharts, medicine, naps, illness, homework, growth, presents, dog, artwork, yearbook, health, fitness, house, photos, birthdays, caregiver

    var id: String { rawValue }
}

/// A stable destination inside the private Fitness module. Keeping this typed
/// prevents Today and Calendar from degrading precise actions into a generic
/// "open Fitness" hand-off.
enum FitnessDeepLinkDestination: String, Codable, Hashable {
    case overview, activities, log, plan, progress, coach
}

struct FitnessDeepLinkIntent: Identifiable, Equatable, Hashable {
    let id: UUID
    let destination: FitnessDeepLinkDestination
    let targetId: String?
    let actionKind: String?
    let coachDestination: FitnessCoachProposalDestination?

    init(
        id: UUID = UUID(),
        destination: FitnessDeepLinkDestination,
        targetId: String? = nil,
        actionKind: String? = nil,
        coachDestination: FitnessCoachProposalDestination? = nil
    ) {
        self.id = id
        self.destination = destination
        self.targetId = targetId
        self.actionKind = actionKind
        self.coachDestination = coachDestination
    }
}

struct FitnessCoachDraftHandoff: Equatable, Sendable {
    let text: String
    let contextIds: [String]
}

enum ListsRoute: String, Identifiable, Hashable {
    // Renewals lives with the Lists "stay ahead" grouping, mirroring web.
    case tasks, meals, routines, renewals, prepPacks

    var id: String { rawValue }
}

/// Global observable state shared across the entire app via @EnvironmentObject.
@MainActor
final class AppState: ObservableObject {
    private static let logger = Logger(
        subsystem: "org.example.hausklar",
        category: "AppState"
    )

    // MARK: - Published Properties

    @Published var isAuthenticated: Bool = false
    @Published var mustChangePassword: Bool = false
    @Published var currentUser: UserProfile? {
        didSet {
            guard oldValue?.id != currentUser?.id else { return }
            clearAssistantWorkspaceState()
        }
    }
    @Published var isOnline: Bool = true
    @Published var selectedTab: AppTab = .today
    @Published var familyRoute: FamilyRoute?
    @Published var selectedFitnessDestination: FitnessDeepLinkDestination = .progress
    @Published var fitnessDeepLinkIntent: FitnessDeepLinkIntent?
    @Published var preferredFamilyChildId: String?
    @Published var preferredFamilyProfileRequestId: UUID?
    @Published var preferredHomeworkItemId: String?
    @Published var preferredReadingItemId: String?
    @Published var preferredPresentItemId: String?
    @Published var preferredMedicineTypeId: String?
    @Published var preferredNapId: String?
    @Published var preferredStarChartId: String?
    @Published var preferredVaccinationKey: String?
    @Published var medicineReviewRequestId: UUID?
    @Published var listsRoute: ListsRoute?
    @Published var preferredMealsSection: Int?
    @Published var preferredTescoSubpage: Int?
    @Published var highlightedCalendarResultId: String?
    @Published var preferredCalendarDate: Date?
    @Published var highlightedTaskResultId: String?
    @Published var highlightedRenewalResultId: String?
    @Published var highlightedDocumentResultId: String?
    @Published var highlightedPhotoResultId: String?
    @Published var highlightedArtworkResultId: String?
    @Published var highlightedBirthdayResultId: String?
    @Published var preferredTaskShowCompleted = false
    @Published var highlightedShoppingResultId: String?
    @Published var showingSettings = false
    @Published var showingDocumentCapture = false
    @Published var showingUniversalCapture = false
    @Published var showingAddHub = false
    @Published var showingAssistantChat = false
    @Published var assistantDraftText: String?
    @Published private(set) var fitnessCoachDraftText: String?
    @Published private(set) var fitnessCoachDraftNonce: UUID?
    @Published private(set) var fitnessCoachContextIds: [String] = []
    @Published var sharedCaptureText: String?
    @Published var sharedCaptureFileURL: URL?
    @Published private(set) var sharedCaptureClaim: SharedCaptureClaim?
    @Published var hasStoredSession: Bool = false
    @Published var biometricErrorMessage: String?
    @Published var isSecuringLocalData = false
    @Published var localDataErrorMessage: String?
    @Published var localDataNoticeMessage: String?
    @Published var localFitnessRecoveryURLs: [URL] = []
    @Published private(set) var fitnessWorkspacePreference = FitnessWorkspacePreference.disabled
    @Published private(set) var isUpdatingFitnessWorkspace = false
    @Published var fitnessWorkspaceErrorMessage: String?
    @Published var showingFitnessOptIn = false
    @Published private(set) var tabBarSlots: [CustomTabDestination] = [.lists, .house]

    private var storedTabBarSlots: [CustomTabDestination]?

    var availableCustomTabDestinations: [CustomTabDestination] {
        TabBarPreferencePolicy.available(
            hasFamilyAccount: currentUser?.familyId != nil,
            fitnessEnabled: fitnessWorkspacePreference.enabled
        )
    }

    var visibleTabBarSlots: [CustomTabDestination] {
        TabBarPreferencePolicy.visible(
            preferred: tabBarSlots,
            selectedTab: selectedTab,
            available: availableCustomTabDestinations
        )
    }

    func saveTabBarSlots(_ slots: [CustomTabDestination]) {
        guard let user = currentUser else { return }
        let available = availableCustomTabDestinations
        var unique: [CustomTabDestination] = []
        for destination in slots where available.contains(destination) && !unique.contains(destination) {
            unique.append(destination)
        }
        guard unique.count == TabBarPreferencePolicy.slotCount else { return }
        storedTabBarSlots = unique
        identityDefaults.set(
            unique.map(\.rawValue),
            forKey: OwnerScopedPreferences.mainTabSlots(identity: Self.cacheIdentity(for: user))
        )
        refreshTabBarSlots()
        HapticManager.success()
    }

    func openCustomTab(_ destination: CustomTabDestination) {
        guard availableCustomTabDestinations.contains(destination) else { return }
        familyRoute = nil
        selectedTab = destination.appTab
    }


    func openFamily(_ route: FamilyRoute, childId: String? = nil) {
        // Keep old callers and stored navigation values working while Fitness is
        // promoted from a Family card to its own primary destination.
        if route == .fitness {
            openFitness(destination: .progress)
            return
        }
        // A nil child means a household-level destination. Clear any previous
        // child context so routes such as Documents do not inherit a stale filter.
        preferredFamilyChildId = childId
        preferredFamilyProfileRequestId = nil
        preferredHomeworkItemId = nil
        preferredReadingItemId = nil
        preferredPresentItemId = nil
        preferredMedicineTypeId = nil
        preferredNapId = nil
        preferredStarChartId = nil
        preferredVaccinationKey = nil
        medicineReviewRequestId = nil
        fitnessDeepLinkIntent = nil
        highlightedDocumentResultId = nil
        highlightedPhotoResultId = nil
        highlightedArtworkResultId = nil
        highlightedBirthdayResultId = nil
        familyRoute = route
        selectedTab = .family
    }

    func openHomework(childId: String, spellingsId: String? = nil) {
        preferredFamilyChildId = childId
        preferredHomeworkItemId = spellingsId
        preferredPresentItemId = nil
        preferredMedicineTypeId = nil
        medicineReviewRequestId = nil
        fitnessDeepLinkIntent = nil
        familyRoute = .homework
        selectedTab = .family
    }

    func openPresent(childId: String, presentId: String? = nil) {
        preferredFamilyChildId = childId
        preferredPresentItemId = presentId
        preferredHomeworkItemId = nil
        preferredMedicineTypeId = nil
        medicineReviewRequestId = nil
        fitnessDeepLinkIntent = nil
        familyRoute = .presents
        selectedTab = .family
    }

    func openMedicineReview(childId: String?, medicineTypeId: String?) {
        preferredFamilyChildId = childId
        preferredMedicineTypeId = medicineTypeId
        preferredPresentItemId = nil
        preferredNapId = nil
        preferredStarChartId = nil
        medicineReviewRequestId = UUID()
        fitnessDeepLinkIntent = nil
        familyRoute = .medicine
        selectedTab = .family
    }

    func openActiveNap(napId: String?, childId: String?) {
        openFamily(.naps, childId: childId)
        preferredNapId = napId
    }

    func openStarChart(chartId: String?, childId: String?) {
        openFamily(.starCharts, childId: childId)
        preferredStarChartId = chartId
    }

    func openCapturedText(_ text: String?) {
        sharedCaptureText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        showingUniversalCapture = true
    }

    func openPhoto(assetId: String) {
        openFamily(.photos)
        highlightedPhotoResultId = assetId
    }

    func openFitness(
        destination: FitnessDeepLinkDestination,
        targetId: String? = nil,
        actionKind: String? = nil,
        coachDestination: FitnessCoachProposalDestination? = nil
    ) {
        let resolvedDestination: FitnessDeepLinkDestination = actionKind == "open_activity"
            ? .activities
            : destination
        preferredFamilyChildId = nil
        preferredPresentItemId = nil
        preferredNapId = nil
        preferredStarChartId = nil
        selectedFitnessDestination = resolvedDestination
        fitnessDeepLinkIntent = FitnessDeepLinkIntent(
            destination: resolvedDestination,
            targetId: targetId,
            actionKind: actionKind,
            coachDestination: coachDestination
        )
        familyRoute = nil
        guard fitnessWorkspacePreference.enabled else {
            showingFitnessOptIn = true
            return
        }
        selectedTab = .fitness
    }

    func loadFitnessWorkspacePreference() async {
        do {
            let preference = try await FitnessNutritionService.shared.workspacePreference(
                refresh: true
            )
            applyFitnessWorkspacePreference(preference)
            fitnessWorkspaceErrorMessage = nil
            if preference.enabled, showingFitnessOptIn {
                showingFitnessOptIn = false
                selectedTab = .fitness
            }
        } catch {
            fitnessWorkspaceErrorMessage = "Fitness preferences could not be updated. Your last choice is still in use."
        }
    }

    @discardableResult
    func updateFitnessWorkspace(
        enabled: Bool? = nil,
        pinned: Bool? = nil,
        showNutritionToday: Bool? = nil
    ) async -> Bool {
        guard !isUpdatingFitnessWorkspace else { return false }
        isUpdatingFitnessWorkspace = true
        fitnessWorkspaceErrorMessage = nil
        defer { isUpdatingFitnessWorkspace = false }
        do {
            let preference = try await FitnessNutritionService.shared.updateWorkspacePreference(
                enabled: enabled,
                pinned: pinned,
                showNutritionToday: showNutritionToday
            )
            applyFitnessWorkspacePreference(preference)
            if let user = currentUser {
                await configureFitnessBackgroundServices(
                    identity: Self.cacheIdentity(for: user),
                    enabled: preference.enabled
                )
            }
            if !preference.enabled {
                showingFitnessOptIn = false
                fitnessDeepLinkIntent = nil
                if selectedTab == .fitness { selectedTab = .today }
            }
            HapticManager.success()
            return true
        } catch {
            fitnessWorkspaceErrorMessage = "That Fitness preference could not be saved. Try again when you are connected."
            HapticManager.error()
            return false
        }
    }

    @discardableResult
    func enableFitnessAndOpen() async -> Bool {
        guard await updateFitnessWorkspace(enabled: true, pinned: true) else { return false }
        showingFitnessOptIn = false
        selectedTab = .fitness
        return true
    }

    /// Routes a confirmed Coach result to its exact owner or family module.
    /// Unknown server destinations are deliberately inert so a future contract
    /// cannot degrade into a misleading generic screen.
    @discardableResult
    func openFitnessCoachDestination(_ destination: FitnessCoachProposalDestination) -> Bool {
        guard destination.kind.isKnown else { return false }
        switch destination.kind {
        case .plannedSession:
            openFitness(
                destination: .plan,targetId: destination.target,
                actionKind: "open_coach_result",coachDestination: destination
            )
        case .nutritionTarget, .mealTemplate, .foodLog:
            openFitness(
                destination: .log,targetId: destination.target,
                actionKind: "open_coach_result",coachDestination: destination
            )
        case .goal:
            openFitness(
                destination: .plan,targetId: destination.target,
                actionKind: "open_coach_result",coachDestination: destination
            )
        case .analysisChart:
            openFitness(
                destination: .progress,targetId: destination.target,
                actionKind: "open_coach_result",coachDestination: destination
            )
        case .fitnessReminder:
            openFitness(
                destination: .coach,targetId: destination.target,
                actionKind: "open_coach_result",coachDestination: destination
            )
        case .calendarEvent:
            highlightedCalendarResultId = destination.target
            preferredCalendarDate = nil
            fitnessDeepLinkIntent = nil
            selectedTab = .calendar
        case .shopping:
            highlightedShoppingResultId = destination.target
            preferredMealsSection = 2
            preferredTescoSubpage = 1
            fitnessDeepLinkIntent = nil
            openLists(.meals)
        case .task:
            highlightedTaskResultId = destination.target
            preferredTaskShowCompleted = false
            fitnessDeepLinkIntent = nil
            openLists(.tasks)
        case .unknown:
            return false
        }
        return true
    }

    /// Stages an exact, unsent Coach draft for the signed-in adult. The
    /// nonce lets an already-mounted Coach consume each hand-off only once.
    @discardableResult
    func stageFitnessCoachDraft(
        _ draft: String,
        contextIds: [String] = []
    ) -> UUID? {
        guard let ownerId = currentUser?.id,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contextIds.count <= 20,
              Set(contextIds).count == contextIds.count,
              contextIds.allSatisfy({ !$0.isEmpty && $0.count <= 100 })
        else { return nil }
        let nonce = UUID()
        fitnessCoachDraftText = draft
        fitnessCoachDraftNonce = nonce
        fitnessCoachContextIds = contextIds
        fitnessCoachDraftOwnerId = ownerId
        return nonce
    }

    /// Returns the staged draft only when the destination composer is empty.
    /// A non-empty Coach draft always wins and leaves the hand-off available.
    func consumeFitnessCoachHandoff(
        nonce: UUID,
        currentDraft: String
    ) -> FitnessCoachDraftHandoff? {
        guard currentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fitnessCoachDraftNonce == nonce,
              fitnessCoachDraftOwnerId == currentUser?.id,
              let draft = fitnessCoachDraftText else { return nil }
        let handoff = FitnessCoachDraftHandoff(
            text: draft,
            contextIds: fitnessCoachContextIds
        )
        clearFitnessCoachDraft()
        return handoff
    }

    /// Compatibility convenience for text-only callers.
    func consumeFitnessCoachDraft(nonce: UUID, currentDraft: String) -> String? {
        consumeFitnessCoachHandoff(nonce: nonce, currentDraft: currentDraft)?.text
    }

    func clearFitnessCoachDraft() {
        fitnessCoachDraftText = nil
        fitnessCoachDraftNonce = nil
        fitnessCoachContextIds = []
        fitnessCoachDraftOwnerId = nil
    }

    /// Clears only the intent that a Fitness shell successfully handled. A
    /// newer intent must never be discarded by an older asynchronous action.
    func completeFitnessDeepLink(id: UUID) {
        guard fitnessDeepLinkIntent?.id == id else { return }
        fitnessDeepLinkIntent = nil
    }

    func openLists(_ route: ListsRoute) {
        listsRoute = route
        selectedTab = .lists
    }

    func openSearchResult(_ result: GlobalSearchResultDTO) {
        highlightedCalendarResultId = nil
        highlightedTaskResultId = nil
        highlightedRenewalResultId = nil
        highlightedDocumentResultId = nil
        highlightedPhotoResultId = nil
        highlightedArtworkResultId = nil
        highlightedBirthdayResultId = nil
        preferredReadingItemId = nil

        switch result.kind {
        case .event:
            highlightedCalendarResultId = result.id
            if let value = result.date {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                preferredCalendarDate = formatter.date(from: value)
            } else {
                preferredCalendarDate = nil
            }
            selectedTab = .calendar
        case .task:
            highlightedTaskResultId = result.id
            preferredTaskShowCompleted = result.path.contains("task_status=completed")
            openLists(.tasks)
        case .document:
            openFamily(.documents, childId: result.childId)
            highlightedDocumentResultId = result.id
        case .person:
            preferredFamilyChildId = result.childId
            preferredFamilyProfileRequestId = UUID()
            familyRoute = nil
            selectedTab = .family
        case .photo:
            openFamily(.photos, childId: result.childId)
            highlightedPhotoResultId = result.id
        case .artwork:
            openFamily(.artwork, childId: result.childId)
            highlightedArtworkResultId = result.id
        case .homework:
            openFamily(.homework, childId: result.childId)
            preferredReadingItemId = result.id
        case .health:
            openFamily(.health, childId: result.childId)
            preferredVaccinationKey = result.id
        case .renewal:
            highlightedRenewalResultId = result.id
            openLists(.renewals)
        case .birthday:
            openFamily(.birthdays)
            highlightedBirthdayResultId = result.id
        }
    }

    /// Presents the one shared Add flow, regardless of which feature initiated it.
    /// Keeping this in app state prevents local plus buttons from drifting into
    /// different creation experiences.
    func openAddHub() {
        showingAddHub = true
    }

    func openReminderURL(_ value: String) {
        guard let route = HausKlarReminderRoute(value: value) else { return }
        switch route {
        case .today:
            selectedTab = .today
        case .calendar(let eventID):
            highlightedCalendarResultId = eventID
            selectedTab = .calendar
        case .tasks(let taskID):
            highlightedTaskResultId = taskID
            openLists(.tasks)
        case .renewals(let renewalID):
            highlightedRenewalResultId = renewalID
            openLists(.renewals)
        case .library:
            openLists(.renewals)
        case .meals: openLists(.meals)
        case .routines: openLists(.routines)
        case .prepPacks: openLists(.prepPacks)
        case .family: selectedTab = .family
        case .naps(let napID, let childID):
            openActiveNap(napId: napID, childId: childID)
        }
    }

    func consumeSharedCapture() {
        if sharedCaptureWasDurablyCommitted { acknowledgeSharedCapture() }
        guard isAuthenticated, !showingUniversalCapture, !showingDocumentCapture,
              sharedCaptureClaim == nil,
              let identity = APIClient.shared.cacheIdentity else { return }
        do {
            guard let claim = try SharedCaptureStore.claimNext(for: identity) else { return }
            sharedCaptureClaim = claim
            let payload = claim.payload
            if let path = payload.filePath, FileManager.default.fileExists(atPath: path) {
                sharedCaptureFileURL = URL(fileURLWithPath: path)
                showingDocumentCapture = true
            } else if let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                sharedCaptureText = text
                showingUniversalCapture = true
            } else {
                releaseSharedCapture()
            }
        } catch {
            localDataErrorMessage = error.localizedDescription
        }
    }

    func acknowledgeSharedCapture() {
        guard let claim = sharedCaptureClaim else { return }
        sharedCaptureWasDurablyCommitted = true
        do {
            try SharedCaptureStore.acknowledge(claim)
            sharedCaptureClaim = nil
            sharedCaptureWasDurablyCommitted = false
        } catch {
            localDataErrorMessage = error.localizedDescription
        }
    }

    func releaseSharedCapture() {
        guard let claim = sharedCaptureClaim else { return }
        if sharedCaptureWasDurablyCommitted {
            acknowledgeSharedCapture()
            return
        }
        defer {
            sharedCaptureClaim = nil
            sharedCaptureWasDurablyCommitted = false
        }
        do {
            _ = try SharedCaptureStore.release(claim)
        } catch {
            localDataErrorMessage = error.localizedDescription
        }
    }

    private enum BiometricKind {
        case faceID
        case touchID
        case none
    }

    /// Cached biometric type, evaluated once at init.
    private let cachedBiometricKind: BiometricKind
    private var localModelContext: ModelContext?
    private var identityDefaults = UserDefaults.standard
    private var purgeLocalIdentityData: @MainActor (
        ModelContext,
        UserDefaults
    ) async throws -> Void = {
        try await LocalIdentityDataPurger.purgeAll(modelContext: $0, defaults: $1)
    }
    private var loadStoredSession: () throws -> StoredSessionEnvelope? = {
        try KeychainManager.loadSessionEnvelope()
    }
    private var saveStoredSession: (StoredSessionEnvelope) throws -> Void = {
        try KeychainManager.saveSessionEnvelope($0)
    }
    private var deleteStoredSession: () throws -> Void = {
        try KeychainManager.deleteSessionEnvelope()
    }
    private var requireDurableClientIdentity: () throws -> String = {
        try APIClient.shared.requireClientId()
    }
    private var activateSharedCaptureIdentity: (String) throws -> Void = {
        try SharedCaptureStore.setActiveIdentity($0)
    }
    private var activatePendingFITIdentity: (String) throws -> Void = {
        try FitnessPendingFITInbox.setActiveIdentity($0)
    }
    private var sharedCaptureWasDurablyCommitted = false
    private var fitnessActivationTask: Task<Void, Never>?
    private enum IdentityTransition {
        case login, logout, reauthenticationLock
    }
    private var identityTransition: IdentityTransition?
    private var fitnessCoachDraftOwnerId: String?

    var identityTransitionInProgress: Bool { identityTransition != nil }

    static let localOwnerKey = "security.localStoreOwner"
    static let localResetRequiredKey = "security.localStoreResetRequired"

    private var biometricKind: BiometricKind { cachedBiometricKind }

    var biometricButtonTitle: String {
        switch biometricKind {
        case .faceID:
            return "Unlock with Face ID".localized
        case .touchID:
            return "Unlock with Touch ID".localized
        case .none:
            return "Unlock".localized
        }
    }

    var biometricIconName: String {
        switch biometricKind {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .none:
            return "lock.example_c6e20e62"
        }
    }

    // MARK: - Initializer

    init() {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID:
            cachedBiometricKind = .faceID
        case .touchID:
            cachedBiometricKind = .touchID
        default:
            cachedBiometricKind = .none
        }
    }

    // MARK: - Session Management

    func configureLocalIdentityBoundary(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard,
        purge: @escaping @MainActor (ModelContext, UserDefaults) async throws -> Void = {
            try await LocalIdentityDataPurger.purgeAll(modelContext: $0, defaults: $1)
        }
    ) {
        localModelContext = modelContext
        identityDefaults = defaults
        purgeLocalIdentityData = purge

        // A pending fail-closed reset is authoritative. Do not inspect or adopt
        // an envelope that clearCredentials has already marked for deletion.
        guard !defaults.bool(forKey: Self.localResetRequiredKey) else { return }

        // Upgrade path: older releases had no owner marker. A still-present
        // Keychain profile is authoritative for that existing single-account store,
        // preserving its offline work. Signed-out legacy stores have no such proof
        // and are purged on the next login.
        do {
            if let envelope = try loadStoredSession() {
                guard let data = envelope.userJSON.data(using: .utf8),
                      let user = try? JSONDecoder().decode(UserProfile.self, from: data) else {
                    throw KeychainError.invalidSessionEnvelope
                }
                Self.adoptLegacyOwnerIfNeeded(user: user, defaults: defaults)
            }
        } catch {
            // Missing is represented by nil above. Corruption or an inaccessible
            // Keychain is materially different and must remain visible so a
            // subsequent login cannot silently treat private legacy data as ownerless.
            localDataErrorMessage = error.localizedDescription
        }
    }

    /// Internal injection seam used by deterministic Keychain failure tests.
    /// Production keeps the defaults above.
    func configureSessionEnvelopeStore(
        load: @escaping () throws -> StoredSessionEnvelope?,
        save: @escaping (StoredSessionEnvelope) throws -> Void,
        delete: @escaping () throws -> Void
    ) {
        loadStoredSession = load
        saveStoredSession = save
        deleteStoredSession = delete
    }

    /// Internal seam for proving that authenticated feature stores never
    /// activate while durable mutation provenance is unavailable.
    func configureClientIdentityRequirement(
        _ requirement: @escaping () throws -> String
    ) {
        requireDurableClientIdentity = requirement
    }

    /// Internal deterministic seam for authentication tests. Production keeps
    /// the app-group-backed activation above; tests can prove AppState ordering
    /// without depending on a simulator app-group container.
    func configureSharedCaptureIdentityActivation(
        _ activation: @escaping (String) throws -> Void
    ) {
        activateSharedCaptureIdentity = activation
    }

    /// Internal deterministic seam for proving that authentication is not
    /// published when the app/share-extension FIT boundary cannot advance.
    func configurePendingFITIdentityActivation(
        _ activation: @escaping (String) throws -> Void
    ) {
        activatePendingFITIdentity = activation
    }

    /// Called after a successful login. Persists tokens in Keychain and updates state.
    func login(accessToken: String, refreshToken: String, user: UserProfile) async throws {
        guard identityTransition == nil else { throw LocalIdentityBoundaryError.transitionInProgress }
        do {
            _ = try requireDurableClientIdentity()
            // A throwing read distinguishes an absent prior session from a
            // temporarily inaccessible/corrupt one before any owner transition.
            _ = try loadStoredSession()
        } catch {
            localDataErrorMessage = error.localizedDescription
            throw error
        }
        identityTransition = .login
        isSecuringLocalData = true
        localDataErrorMessage = nil
        defer {
            identityTransition = nil
            isSecuringLocalData = false
        }
        do {
            await cancelFitnessActivationAndWait()
            let incomingIdentity = Self.cacheIdentity(for: user)
            if APIClient.shared.currentSessionSnapshot() != nil {
                DocumentUploadService.shared.suspend()
                await DocumentUploadService.shared.waitForSuspendedWork()
            }
            if let activeIdentity = APIClient.shared.cacheIdentity,
               activeIdentity != incomingIdentity {
                // Invalidate and cancel A's requests before purging A's cache.
                // Otherwise a late A response could write private data behind
                // the completed purge while B is being prepared.
                APIClient.shared.clearSession()
            }
            try await prepareLocalIdentity(for: user)
            try installSession(accessToken: accessToken, refreshToken: refreshToken, user: user)
        } catch {
            await cancelFitnessActivationAndWait()
            await purgeTransientExportsBestEffort(context: "failed login")
            localDataErrorMessage = error.localizedDescription
            captureFitnessRecoveryURLs(from: error)
            DocumentUploadService.shared.suspend()
            await DocumentUploadService.shared.waitForSuspendedWork()
            GlanceStore.suspend()
            await HomeSnapshotStore.shared.suspend()
            await FitnessHealthKitService.shared.suspend()
            await FitnessRecoveryService.shared.suspend()
            await FitnessNutritionService.shared.suspend()
            await FitnessActivityService.shared.suspend()
            await FitnessSyncService.shared.suspend()
            FitnessDatabase.shared.suspend()
            FitnessPendingFITInbox.clearActiveIdentity()
            await SyncManager.shared.suspendAndReset()
            clearCredentials()
            throw error
        }
    }

    private func installSession(
        accessToken: String,
        refreshToken: String,
        user: UserProfile,
        persist: Bool = true,
        installAPIClient: Bool = true
    ) throws {
        _ = try requireDurableClientIdentity()
        let userData = try JSONEncoder().encode(user)
        guard let userJSON = String(data: userData, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let identity = Self.cacheIdentity(for: user)
        if persist {
            try saveStoredSession(
                StoredSessionEnvelope(
                    identity: identity,
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    userJSON: userJSON
                )
            )
        }
        if installAPIClient {
            APIClient.shared.installSession(
                identity: identity,
                accessToken: accessToken,
                refreshToken: refreshToken,
                persistTokenRotation: true
            )
        }
        currentUser = user
        isAuthenticated = true
        mustChangePassword = user.mustChangePassword ?? false
        hasStoredSession = false
        biometricErrorMessage = nil
        fitnessWorkspacePreference = cachedFitnessWorkspacePreference(for: user) ?? .disabled
        loadTabBarSlots(for: user)
        fitnessWorkspaceErrorMessage = nil
        showingFitnessOptIn = false
        startFitnessActivation(identity: identity)
    }

    /// Installs the replacement credential pair returned after a password change.
    func passwordChanged(accessToken: String, refreshToken: String, user: UserProfile) async throws {
        try await login(accessToken: accessToken, refreshToken: refreshToken, user: user)
    }

    /// Replace harmless profile display fields while preserving the active credential pair.
    func profileUpdated(_ user: UserProfile) {
        guard currentUser?.id == user.id else { return }
        do {
            let data = try JSONEncoder().encode(user)
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.encodingFailed
            }
            try APIClient.shared.updateStoredProfile(
                identity: Self.cacheIdentity(for: user),
                userJSON: value
            )
            currentUser = user
            refreshTabBarSlots()
        } catch {
            localDataErrorMessage = "Your profile changed, but this device could not cache the new display name."
        }
    }

    /// Clears all session data and returns to the login screen. The reset-required
    /// marker is written first so a crash anywhere in teardown forces another purge.
    func logout() async {
        await performLogout(revoke: nil)
    }

    /// Authentication expiry is a lock, not a destructive logout. Owner-bound
    /// offline work remains encrypted in place and cannot render or sync. A login
    /// for the same identity resumes it; a different identity must pass the purge
    /// in prepareLocalIdentity before activation.
    func lockForReauthentication() async {
        guard identityTransition == nil else { return }
        identityTransition = .reauthenticationLock
        isSecuringLocalData = true
        defer {
            identityTransition = nil
            isSecuringLocalData = false
        }
        NotificationService.shared.stopRemoteNotifications()
        isAuthenticated = false
        await cancelFitnessActivationAndWait()
        DocumentUploadService.shared.suspend()
        await DocumentUploadService.shared.waitForSuspendedWork()
        GlanceStore.suspend()
        await HomeSnapshotStore.shared.suspend()
        await FitnessHealthKitService.shared.suspend()
        await FitnessRecoveryService.shared.suspend()
        await FitnessNutritionService.shared.suspend()
        await FitnessActivityService.shared.suspend()
        await FitnessSyncService.shared.suspend()
        FitnessDatabase.shared.suspend()
        FitnessPendingFITInbox.clearActiveIdentity()
        await SyncManager.shared.suspendAndReset()
        clearCredentials()
        clearSessionState()
        DocumentPreviewStore.purgeAll()
        DocumentCaptureService.purgeTemporaryCaptures()
        await purgeTransientExportsBestEffort(context: "reauthentication lock")
        MedicineActivityManager.shared.endAll()
        NapActivityManager.shared.endAll()
        NotificationService.shared.clearIdentityBoundNotifications()
        do {
            try GlanceStore.clear()
        } catch {
            Self.logger.error(
                "Failed to clear the glance cache during reauthentication: \(error.localizedDescription, privacy: .public)"
            )
        }
        await FileCache.shared.clear()
        localDataNoticeMessage = "Your session expired. Unsynced changes and documents are safely kept on this device; sign back into the same account to resume them."
        WidgetReloader.shared.requestReload(after: 0.5)
    }

    private func performLogout(revoke: (() async throws -> Void)?) async {
        guard identityTransition == nil else { return }
        identityTransition = .logout
        isSecuringLocalData = true
        defer {
            identityTransition = nil
            isSecuringLocalData = false
        }
        await NotificationService.shared.unregisterRemoteNotificationsFromServer()
        isAuthenticated = false
        await cancelFitnessActivationAndWait()
        let offlineMutationOwner = APIClient.shared.cacheIdentity
        identityDefaults.set(true, forKey: Self.localResetRequiredKey)
        DocumentUploadService.shared.suspend()
        await DocumentUploadService.shared.waitForSuspendedWork()
        GlanceStore.suspend()
        await HomeSnapshotStore.shared.suspend()
        await FitnessHealthKitService.shared.suspend()
        await FitnessRecoveryService.shared.suspend()
        await FitnessNutritionService.shared.suspend()
        await FitnessActivityService.shared.suspend()
        await FitnessSyncService.shared.suspend()
        FitnessDatabase.shared.suspend()
        FitnessPendingFITInbox.clearActiveIdentity()
        await SyncManager.shared.suspendAndReset()
        if let revoke {
            do {
                try await revoke()
            } catch {
                // Revocation is intentionally best effort: local logout must still
                // complete while offline, and rotating refresh tokens limit reuse.
                Self.logger.warning(
                    "Refresh-token revocation failed during logout: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        clearCredentials()
        clearSessionState()
        NotificationService.shared.clearIdentityBoundNotifications()

        do {
            guard let localModelContext else { throw LocalIdentityBoundaryError.storeNotConfigured }
            try await purgeLocalIdentityData(localModelContext, identityDefaults)
            if let offlineMutationOwner {
                try await APIClient.shared.purgeOfflineMutations(identity: offlineMutationOwner)
            }
            identityDefaults.removeObject(forKey: Self.localOwnerKey)
            identityDefaults.removeObject(forKey: Self.localResetRequiredKey)
            localDataErrorMessage = nil
        } catch {
            // Keep resetRequired=true. prepareLocalIdentity will retry and will not
            // activate a subsequent account unless the purge and save both succeed.
            localDataErrorMessage = error.localizedDescription
        }
        WidgetReloader.shared.requestReload(after: 0.5)
    }

    private func clearCredentials() {
        APIClient.shared.clearSession()

        do {
            try deleteStoredSession()
        } catch {
            // The reset-required marker prevents restoration after a failed
            // deletion. Keep the error visible and fail closed in memory.
            identityDefaults.set(true, forKey: Self.localResetRequiredKey)
            localDataErrorMessage = error.localizedDescription
        }
    }

    private func clearSessionState() {
        AudiobookService.shared.clearCachedCovers()
        AmbientIntentRouteStore.clear()
        releaseSharedCapture()
        currentUser = nil
        mustChangePassword = false
        hasStoredSession = false
        biometricErrorMessage = nil
        assistantDraftText = nil
        clearFitnessCoachDraft()
        sharedCaptureText = nil
        sharedCaptureFileURL = nil
        showingSettings = false
        showingDocumentCapture = false
        showingUniversalCapture = false
        showingAddHub = false
        showingAssistantChat = false
        showingFitnessOptIn = false
        selectedTab = .today
        familyRoute = nil
        selectedFitnessDestination = .progress
        fitnessDeepLinkIntent = nil
        fitnessWorkspacePreference = .disabled
        storedTabBarSlots = nil
        tabBarSlots = [.lists, .house]
        fitnessWorkspaceErrorMessage = nil
        isUpdatingFitnessWorkspace = false
        preferredFamilyChildId = nil
        preferredFamilyProfileRequestId = nil
        preferredHomeworkItemId = nil
        preferredReadingItemId = nil
        preferredPresentItemId = nil
        preferredMedicineTypeId = nil
        preferredNapId = nil
        preferredStarChartId = nil
        preferredVaccinationKey = nil
        medicineReviewRequestId = nil
        listsRoute = nil
        preferredMealsSection = nil
        preferredTescoSubpage = nil
        highlightedCalendarResultId = nil
        preferredCalendarDate = nil
        highlightedTaskResultId = nil
        highlightedRenewalResultId = nil
        highlightedDocumentResultId = nil
        highlightedPhotoResultId = nil
        highlightedArtworkResultId = nil
        highlightedBirthdayResultId = nil
        preferredTaskShowCompleted = false
        highlightedShoppingResultId = nil
    }

    private func clearAssistantWorkspaceState() {
        assistantDraftText = nil
        clearFitnessCoachDraft()
    }

    func applyFitnessWorkspacePreference(_ preference: FitnessWorkspacePreference) {
        fitnessWorkspacePreference = preference
        refreshTabBarSlots()
        guard let user = currentUser else { return }
        do {
            identityDefaults.set(
                try JSONEncoder().encode(preference),
                forKey: fitnessWorkspaceCacheKey(for: user)
            )
        } catch {
            Self.logger.error(
                "Failed to encode the owner-scoped fitness workspace preference: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func cachedFitnessWorkspacePreference(
        for user: UserProfile
    ) -> FitnessWorkspacePreference? {
        guard let data = identityDefaults.data(forKey: fitnessWorkspaceCacheKey(for: user)) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(FitnessWorkspacePreference.self, from: data)
        } catch {
            identityDefaults.removeObject(forKey: fitnessWorkspaceCacheKey(for: user))
            Self.logger.notice(
                "Discarded an invalid owner-scoped fitness workspace preference: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private func fitnessWorkspaceCacheKey(for user: UserProfile) -> String {
        OwnerScopedPreferences.fitnessWorkspace(familyID: user.familyId, userID: user.id)
    }

    private func loadTabBarSlots(for user: UserProfile) {
        let values = identityDefaults.stringArray(
            forKey: OwnerScopedPreferences.mainTabSlots(identity: Self.cacheIdentity(for: user))
        )
        storedTabBarSlots = values?.compactMap(CustomTabDestination.init(rawValue:))
        refreshTabBarSlots()
    }

    private func refreshTabBarSlots() {
        tabBarSlots = TabBarPreferencePolicy.resolve(
            saved: storedTabBarSlots,
            hasFamilyAccount: currentUser?.familyId != nil,
            fitnessEnabled: fitnessWorkspacePreference.enabled,
            fitnessPinned: fitnessWorkspacePreference.pinned
        )
        if let selected = CustomTabDestination(appTab: selectedTab),
           !availableCustomTabDestinations.contains(selected) {
            selectedTab = .today
        }
    }

    /// Revokes the long-lived refresh token when possible, but never traps the user in a session offline.
    func logoutAndRevoke(
        revoke: @escaping () async throws -> Void = { try await AuthService().logout() }
    ) async {
        await performLogout(revoke: revoke)
    }

    /// These files never contain the durable source of truth, so identity locks
    /// may continue if cleanup fails. Keep each failure observable and rely on the
    /// next fail-closed identity transition to retry the secure purge.
    private func purgeTransientExportsBestEffort(context: String) async {
        DecodedImageCache.shared.suspend()
        do {
            try await SchoolTimetableStaging.purgeAll()
        } catch {
            Self.logger.error(
                "Failed to purge timetable staging during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try await ShareExportStore.shared.securePurgeAll()
        } catch {
            Self.logger.error(
                "Failed to purge share exports during \(context, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Attempts to restore a previous session from Keychain on app launch.
    func restoreSession() async {
        guard !identityDefaults.bool(forKey: Self.localResetRequiredKey) else {
            clearCredentials()
            await purgeTransientExportsBestEffort(context: "required local reset")
            return
        }
        let envelope: StoredSessionEnvelope
        do {
            guard let stored = try loadStoredSession() else {
                await purgeTransientExportsBestEffort(context: "signed-out launch")
                return
            }
            _ = try requireDurableClientIdentity()
            envelope = stored
        } catch {
            await cancelFitnessActivationAndWait()
            localDataErrorMessage = error.localizedDescription
            // Keep the envelope intact. A missing item is handled by the guard;
            // storage/decoding failures must not be reclassified as logout.
            APIClient.shared.clearSession()
            clearSessionState()
            await purgeTransientExportsBestEffort(context: "failed session-envelope load")
            return
        }

        if canRequireBiometricUnlock() {
            hasStoredSession = true
            biometricErrorMessage = nil
            return
        }

        await completeSessionRestore(envelope)
    }

    func unlockStoredSessionWithBiometrics() async {
        guard hasStoredSession else {
            biometricErrorMessage = "Stored session not found. Please log in again.".localized
            return
        }

        do {
            try await authenticateWithDeviceOwner()
            guard let envelope = try loadStoredSession() else {
                throw KeychainError.invalidSessionEnvelope
            }
            await completeSessionRestore(envelope)
            hasStoredSession = false
            biometricErrorMessage = nil
        } catch {
            biometricErrorMessage = "Authentication failed. Please try again or log in with email and password.".localized
        }
    }

    private func completeSessionRestore(_ envelope: StoredSessionEnvelope) async {
        guard identityTransition == nil else { return }
        identityTransition = .login
        await cancelFitnessActivationAndWait()
        guard let userData = envelope.userJSON.data(using: .utf8),
              let storedUser = try? JSONDecoder().decode(UserProfile.self, from: userData),
              Self.cacheIdentity(for: storedUser) == envelope.identity else {
            clearCredentials()
            await purgeTransientExportsBestEffort(context: "invalid session envelope")
            identityTransition = nil
            return
        }

        isSecuringLocalData = true
        localDataErrorMessage = nil
        do {
            APIClient.shared.installSession(
                identity: envelope.identity,
                accessToken: envelope.accessToken,
                refreshToken: envelope.refreshToken,
                persistTokenRotation: true
            )
            let restoredUser: UserProfile
            switch await validateSession(expectedIdentity: envelope.identity) {
            case .valid(let serverUser):
                restoredUser = serverUser
                let data = try JSONEncoder().encode(serverUser)
                guard let userJSON = String(data: data, encoding: .utf8) else {
                    throw KeychainError.encodingFailed
                }
                try saveStoredSession(
                    StoredSessionEnvelope(
                        identity: envelope.identity,
                        accessToken: APIClient.shared.accessToken ?? envelope.accessToken,
                        refreshToken: APIClient.shared.refreshToken ?? envelope.refreshToken,
                        userJSON: userJSON
                    )
                )
            case .offline:
                restoredUser = storedUser
            case .invalid:
                clearCredentials()
                clearSessionState()
                await purgeTransientExportsBestEffort(context: "invalid server session")
                identityTransition = nil
                isSecuringLocalData = false
                return
            }
            try await prepareLocalIdentity(for: restoredUser)
            try installSession(
                accessToken: APIClient.shared.accessToken ?? envelope.accessToken,
                refreshToken: APIClient.shared.refreshToken ?? envelope.refreshToken,
                user: restoredUser,
                persist: false,
                installAPIClient: false
            )
            identityTransition = nil
            isSecuringLocalData = false
        } catch {
            await purgeTransientExportsBestEffort(context: "failed session restore")
            localDataErrorMessage = error.localizedDescription
            captureFitnessRecoveryURLs(from: error)
            DocumentUploadService.shared.suspend()
            await DocumentUploadService.shared.waitForSuspendedWork()
            GlanceStore.suspend()
            await HomeSnapshotStore.shared.suspend()
            await FitnessHealthKitService.shared.suspend()
            await FitnessRecoveryService.shared.suspend()
            await FitnessNutritionService.shared.suspend()
            await FitnessActivityService.shared.suspend()
            await FitnessSyncService.shared.suspend()
            FitnessDatabase.shared.suspend()
            FitnessPendingFITInbox.clearActiveIdentity()
            await SyncManager.shared.suspendAndReset()
            clearCredentials()
            clearSessionState()
            identityTransition = nil
            isSecuringLocalData = false
        }
    }

    private func captureFitnessRecoveryURLs(from error: Error) {
        let candidates: [URL]
        switch error {
        case FitnessDatabaseError.migrationFailed(let store, let backup, _):
            candidates = [backup, store].compactMap { $0 }
        case FitnessDatabaseError.unverifiedLegacyStore(let store):
            candidates = [store]
        default:
            return
        }
        localFitnessRecoveryURLs=Array(Set(candidates)).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func canRequireBiometricUnlock() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    private static func cacheIdentity(for user: UserProfile) -> String {
        "\(user.familyId ?? "no-family"):\(user.id)"
    }

    private func sessionStillOwnsFitness(_ identity: String) -> Bool {
        guard !Task.isCancelled,
              isAuthenticated,
              APIClient.shared.cacheIdentity == identity,
              let currentUser else { return false }
        return Self.cacheIdentity(for: currentUser) == identity
    }

    private func startFitnessActivation(identity: String) {
        let previousActivation = fitnessActivationTask
        previousActivation?.cancel()
        fitnessActivationTask = Task { @MainActor [weak self] in
            await previousActivation?.value
            guard let self, self.sessionStillOwnsFitness(identity) else { return }
            await FitnessRecoveryService.shared.activate(identity: identity)
            guard self.sessionStillOwnsFitness(identity) else { return }
            await FitnessNutritionService.shared.activate(identity: identity)
            guard self.sessionStillOwnsFitness(identity) else { return }
            await FitnessActivityService.shared.activate(identity: identity)
            guard self.sessionStillOwnsFitness(identity) else { return }
            await self.loadFitnessWorkspacePreference()
            guard self.sessionStillOwnsFitness(identity) else { return }
            await self.configureFitnessBackgroundServices(
                identity: identity,
                enabled: self.fitnessWorkspacePreference.enabled
            )
        }
    }

    private func cancelFitnessActivationAndWait() async {
        guard let task = fitnessActivationTask else { return }
        fitnessActivationTask = nil
        task.cancel()
        await task.value
    }

    private func configureFitnessBackgroundServices(
        identity: String,
        enabled: Bool
    ) async {
        guard sessionStillOwnsFitness(identity) else { return }
        if enabled {
            await FitnessHealthKitService.shared.activate(identity: identity)
            guard sessionStillOwnsFitness(identity) else {
                await FitnessHealthKitService.shared.suspend()
                return
            }
            await FitnessSyncService.shared.activate(identity: identity)
        } else {
            await FitnessHealthKitService.shared.suspend()
            await FitnessSyncService.shared.suspend()
        }
    }

    @discardableResult
    static func adoptLegacyOwnerIfNeeded(user: UserProfile, defaults: UserDefaults) -> Bool {
        guard defaults.string(forKey: localOwnerKey) == nil,
              !defaults.bool(forKey: localResetRequiredKey) else { return false }
        defaults.set(cacheIdentity(for: user), forKey: localOwnerKey)
        return true
    }

    private func prepareLocalIdentity(for user: UserProfile) async throws {
        guard let localModelContext else { throw LocalIdentityBoundaryError.storeNotConfigured }
        let identity = Self.cacheIdentity(for: user)
        let storedOwner = identityDefaults.string(forKey: Self.localOwnerKey)
        let resetRequired = identityDefaults.bool(forKey: Self.localResetRequiredKey)
        let shouldReportLegacyReset = try storedOwner == nil
            && LocalIdentityDataPurger.hasAnyRecords(localModelContext)

        if resetRequired || storedOwner != identity {
            identityDefaults.set(true, forKey: Self.localResetRequiredKey)
            NotificationService.shared.stopRemoteNotifications()
            NotificationService.shared.clearIdentityBoundNotifications()
            await cancelFitnessActivationAndWait()
            DocumentUploadService.shared.suspend()
            await DocumentUploadService.shared.waitForSuspendedWork()
            GlanceStore.suspend()
            await HomeSnapshotStore.shared.suspend()
            await FitnessHealthKitService.shared.suspend()
            await FitnessRecoveryService.shared.suspend()
            await FitnessNutritionService.shared.suspend()
            await FitnessActivityService.shared.suspend()
            await FitnessSyncService.shared.suspend()
            FitnessPendingFITInbox.clearActiveIdentity()
            await SyncManager.shared.suspendAndReset()
            FitnessDatabase.shared.suspend()
            if let storedOwner {
                try await APIClient.shared.purgeOfflineMutations(identity: storedOwner)
            }
            try await purgeLocalIdentityData(localModelContext, identityDefaults)
            identityDefaults.set(identity, forKey: Self.localOwnerKey)
            identityDefaults.removeObject(forKey: Self.localResetRequiredKey)
            if shouldReportLegacyReset {
                localDataNoticeMessage = "For privacy, HausKlar removed unsynced local data left by a previously signed-out account."
            }
        }

        // Activation is deliberately last. Neither loop can queue, pull or upload
        // while a previous owner is still present or a purge is incomplete.
        let legacyOwnerProof = identityDefaults.string(forKey: Self.localOwnerKey)
        let fitnessActivation = Task.detached(priority: .userInitiated) {
            try FitnessDatabase.shared.activate(
                identity: identity,
                legacyOwnerProof: legacyOwnerProof
            )
        }
        try await fitnessActivation.value
        try activatePendingFITIdentity(identity)
        try activateSharedCaptureIdentity(identity)
        SyncManager.shared.activate(identity: identity)
        DocumentUploadService.shared.activate(identity: identity)
        GlanceStore.activate(identity: identity)
        await HomeSnapshotStore.shared.activate(identity: identity)
        try await SchoolTimetableStaging.purgeAll()
        try await ShareExportStore.shared.activate(identity: identity)
        DecodedImageCache.shared.activate(identity: identity)
    }

    private func authenticateWithDeviceOwner() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let context = LAContext()
            context.localizedCancelTitle = "Use Password".localized
            let reason = "Unlock HausKlar with Face ID or your device passcode.".localized
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: error ?? LAError(.authenticationFailed))
                }
            }
        }
    }

    private enum SessionValidation {
        case valid(UserProfile)
        case offline
        case invalid
    }

    /// A stored, identity-bound session remains usable offline when validation
    /// failed for a transient service/transport reason. Only a definitive auth or
    /// request rejection should erase credentials and force reauthentication.
    static func isTransientSessionValidationError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .networkError, .decodingError:
            return true
        case .serverError(let statusCode, _):
            return [408, 425, 429].contains(statusCode)
                || (500...599).contains(statusCode)
        case .invalidURL, .unauthorized, .forbidden, .notFound, .conflict,
             .offlineQueued, .offlineQueueFull, .tokenRefreshFailed:
            return false
        }
    }

    /// Validates both the credential and its identity. A successful `/auth/me`
    /// response must match the envelope; only a transport failure permits an
    /// offline restore from the already validated local profile.
    private func validateSession(expectedIdentity: String) async -> SessionValidation {
        do {
            let user: UserProfile = try await APIClient.shared.get(
                "/auth/me",
                cachePolicy: .networkOnly
            )
            guard Self.cacheIdentity(for: user) == expectedIdentity else { return .invalid }
            return .valid(user)
        } catch {
            return Self.isTransientSessionValidationError(error) ? .offline : .invalid
        }
    }
}
