import AuthenticationServices
import Combine
import Foundation
import UIKit

enum FitnessIntervalsAuthorizationError: LocalizedError {
    case couldNotStart
    case invalidCallback
    case providerRejected

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Intervals.icu sign-in could not be opened."
        case .invalidCallback:
            "Intervals.icu sign-in did not return to HausKlar."
        case .providerRejected:
            "Intervals.icu did not complete the connection. Try again."
        }
    }
}

@MainActor
protocol FitnessIntervalsAuthorizing: AnyObject {
    func authenticate(at url: URL) async throws -> URL
}

@MainActor
final class FitnessIntervalsAuthorizationSession: NSObject,
    FitnessIntervalsAuthorizing,
    ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "hausklar") {
                [weak self] callback, error in
                self?.session = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: FitnessIntervalsAuthorizationError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: FitnessIntervalsAuthorizationError.couldNotStart)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}

@MainActor
final class FitnessIntervalsViewModel: FitnessViewModelBase {
    @Published private(set) var status: FitnessIntervalsStatus?
    @Published private(set) var deliveries: [String: FitnessIntervalsDelivery] = [:]
    @Published private(set) var operationMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isBulkSyncing = false
    @Published private(set) var loadingSessionIds: Set<String> = []
    @Published private(set) var sendingSessionIds: Set<String> = []

    private let service: any FitnessIntervalsServing
    private let authorizationSession: any FitnessIntervalsAuthorizing
    private let ownerContextProvider: () -> FitnessIntervalsOwnerContext?
    private var activeOwner: FitnessIntervalsOwnerContext?

    init(
        service: any FitnessIntervalsServing = FitnessIntervalsService.shared,
        authorizationSession: (any FitnessIntervalsAuthorizing)? = nil,
        ownerContextProvider: @escaping () -> FitnessIntervalsOwnerContext? = {
            APIClient.shared.currentSessionSnapshot().map {
                FitnessIntervalsOwnerContext(identity: $0.identity, generation: $0.generation)
            }
        }
    ) {
        self.service = service
        self.authorizationSession = authorizationSession ?? FitnessIntervalsAuthorizationSession()
        self.ownerContextProvider = ownerContextProvider
        super.init()
    }

    var isConnected: Bool {
        status?.connected == true
    }

    func delivery(for plannedSessionId: String) -> FitnessIntervalsDelivery? {
        deliveries[plannedSessionId]
    }

    func load() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        defer {
            if isCurrent(owner) { isWorking = false }
        }
        do {
            let response = try await service.loadStatus()
            guard isCurrent(owner) else { return }
            status = response
            if !response.connected { deliveries = [:] }
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    @discardableResult
    func connect(apiKey: String) async -> Bool {
        guard !isWorking, let owner = prepareOwner() else { return false }
        let candidate = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 8 else {
            errorMessage = "Enter your Intervals.icu personal API key."
            HapticManager.error()
            return false
        }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { isWorking = false }
        }
        do {
            let response = try await service.connect(apiKey: candidate)
            guard isCurrent(owner) else { return false }
            status = response
            deliveries = [:]
            operationMessage = "Intervals.icu connected."
            HapticManager.success()
            return true
        } catch {
            guard isCurrent(owner) else { return false }
            errorMessage = error.localizedDescription
            HapticManager.error()
            return false
        }
    }

    func connectWithOAuth() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { isWorking = false }
        }
        do {
            let start = try await service.startOAuth()
            guard isCurrent(owner),
                  let authorizationURL = ProviderAuthorizationURLPolicy.validatedURL(
                      start.authorizationUrl,
                      provider: .intervals
                  ) else {
                throw FitnessIntervalsAuthorizationError.providerRejected
            }
            let callback = try await authorizationSession.authenticate(at: authorizationURL)
            guard isCurrent(owner) else { return }
            guard let outcome = HausKlarAuthorizationCallback(
                url: callback,
                provider: .intervals
            ) else {
                throw FitnessIntervalsAuthorizationError.invalidCallback
            }
            if outcome == .cancelled {
                operationMessage = "Intervals.icu connection cancelled."
                return
            }
            guard outcome == .connected else {
                throw FitnessIntervalsAuthorizationError.providerRejected
            }
            let response = try await service.loadStatus()
            guard isCurrent(owner) else { return }
            status = response
            deliveries = [:]
            operationMessage = "Intervals.icu connected."
            HapticManager.success()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            guard isCurrent(owner) else { return }
            operationMessage = "Intervals.icu connection cancelled."
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func testConnection() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { isWorking = false }
        }
        do {
            let response = try await service.testConnection()
            guard isCurrent(owner) else { return }
            status = response
            if !response.connected { deliveries = [:] }
            operationMessage = response.connected
                ? "Intervals.icu connection checked."
                : "Intervals.icu needs attention."
            if response.connected { HapticManager.success() }
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func setActivityImport(enabled: Bool) async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { isWorking = false }
        }
        do {
            let response = try await service.updateActivityImport(
                enabled: enabled,
                lookbackDays: 30
            )
            guard isCurrent(owner) else { return }
            status = response
            if enabled {
                let result = try await service.syncActivities()
                guard isCurrent(owner) else { return }
                status = result.status
                operationMessage = result.queuedCount == 0
                    ? "Garmin activities are up to date."
                    : "\(result.queuedCount) Garmin activit\(result.queuedCount == 1 ? "y is" : "ies are") being imported."
            } else {
                operationMessage = "Garmin activity import is off."
            }
            HapticManager.success()
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func importActivitiesNow() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { isWorking = false }
        }
        do {
            let result = try await service.syncActivities()
            guard isCurrent(owner) else { return }
            status = result.status
            operationMessage = result.queuedCount == 0
                ? "Garmin activities are up to date."
                : "\(result.queuedCount) Garmin activit\(result.queuedCount == 1 ? "y is" : "ies are") being imported."
            HapticManager.success()
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func disconnect() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { isWorking = false }
        }
        do {
            let result = try await service.disconnect()
            guard isCurrent(owner) else { return }
            let previous = status
            status = FitnessIntervalsStatus(
                configured: previous?.configured ?? true,
                oauthAvailable: previous?.oauthAvailable ?? false,
                personalApiKeyAvailable: previous?.personalApiKeyAvailable ?? false,
                connected: false,
                status: result.status,
                authMethod: nil,
                oauthScopes: previous?.oauthScopes ?? [],
                athleteId: nil,
                athleteName: nil,
                garminTrainingConnected: nil,
                lastTestedAt: previous?.lastTestedAt,
                lastErrorCode: nil,
                activityReadAuthorized: false,
                activityImportEnabled: false,
                activityImportSince: nil,
                lastActivityImportAt: previous?.lastActivityImportAt,
                lastActivityImportErrorCode: nil,
                activityImportedCount: previous?.activityImportedCount ?? 0,
                activityImportPendingCount: 0,
                activityImportErrorCount: previous?.activityImportErrorCount ?? 0
            )
            deliveries = [:]
            operationMessage = "Intervals.icu disconnected."
            HapticManager.success()
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func loadDelivery(for plan: FitnessPlannedSession) async {
        guard let owner = prepareOwner(), plan.isIntervalsDeliveryEligible, isConnected,
              !loadingSessionIds.contains(plan.id) else { return }
        loadingSessionIds.insert(plan.id)
        defer {
            if isCurrent(owner) { loadingSessionIds.remove(plan.id) }
        }
        do {
            let response = try await service.loadDelivery(plannedSessionId: plan.id)
            guard isCurrent(owner) else { return }
            deliveries[plan.id] = response
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func send(_ plan: FitnessPlannedSession) async {
        guard let owner = prepareOwner() else { return }
        guard plan.isIntervalsDeliveryEligible else {
            errorMessage = "Accept and schedule this run before sending it."
            HapticManager.error()
            return
        }
        guard isConnected else {
            errorMessage = "Connect Intervals.icu before sending this run."
            HapticManager.error()
            return
        }
        guard !sendingSessionIds.contains(plan.id) else { return }
        sendingSessionIds.insert(plan.id)
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { sendingSessionIds.remove(plan.id) }
        }
        do {
            let response = try await service.send(plannedSessionId: plan.id)
            guard isCurrent(owner) else { return }
            deliveries[plan.id] = response
            switch response.state {
            case .sent:
                operationMessage = "Sent to Intervals.icu"
                HapticManager.success()
            case .pending:
                operationMessage = "Updating Intervals.icu…"
            case .error:
                errorMessage = response.lastErrorCode.map(errorDescription) ?? "Intervals.icu could not update this run. Try again."
                HapticManager.error()
            case .notSent, .cancelled:
                operationMessage = "The run was not sent to Intervals.icu."
            }
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    func sync(_ plans: [FitnessPlannedSession]) async {
        let eligible = plans.filter(\.isIntervalsDeliveryEligible)
        guard let owner = prepareOwner(), !eligible.isEmpty, !isBulkSyncing, isConnected else { return }
        isBulkSyncing = true
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { isBulkSyncing = false }
        }

        var sent = 0
        var pending = 0
        var failed = 0
        for plan in eligible {
            guard isCurrent(owner) else { return }
            sendingSessionIds.insert(plan.id)
            do {
                let response = try await service.send(plannedSessionId: plan.id)
                guard isCurrent(owner) else { return }
                deliveries[plan.id] = response
                switch response.state {
                case .sent: sent += 1
                case .pending: pending += 1
                case .error, .notSent, .cancelled: failed += 1
                }
            } catch {
                guard isCurrent(owner) else { return }
                failed += 1
            }
            sendingSessionIds.remove(plan.id)
        }

        guard isCurrent(owner) else { return }
        if failed == 0 {
            if pending > 0 {
                operationMessage = "Updating Intervals.icu…"
            } else {
                operationMessage = sent == 1
                    ? "Sent to Intervals.icu"
                    : "Sent \(sent) runs to Intervals.icu"
                HapticManager.success()
            }
        } else {
            operationMessage = sent == 0 ? nil : "Sent \(sent) run\(sent == 1 ? "" : "s") to Intervals.icu."
            errorMessage = "\(failed) run\(failed == 1 ? "" : "s") could not be updated. Try again."
            HapticManager.error()
        }
    }

    func cancel(_ plan: FitnessPlannedSession) async {
        guard let owner = prepareOwner(), isConnected,
              !sendingSessionIds.contains(plan.id) else { return }
        sendingSessionIds.insert(plan.id)
        errorMessage = nil
        operationMessage = nil
        defer {
            if isCurrent(owner) { sendingSessionIds.remove(plan.id) }
        }
        do {
            let response = try await service.cancel(plannedSessionId: plan.id)
            guard isCurrent(owner) else { return }
            deliveries[plan.id] = response
            operationMessage = "Removed from Intervals.icu."
            HapticManager.success()
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    private func prepareOwner() -> FitnessIntervalsOwnerContext? {
        let current = ownerContextProvider()
        guard activeOwner == current else {
            activeOwner = current
            status = nil
            deliveries = [:]
            operationMessage = nil
            errorMessage = nil
            isWorking = false
            isBulkSyncing = false
            loadingSessionIds = []
            sendingSessionIds = []
            return current
        }
        return current
    }

    private func isCurrent(_ owner: FitnessIntervalsOwnerContext) -> Bool {
        activeOwner == owner && ownerContextProvider() == owner
    }

    private func errorDescription(_ code: String) -> String {
        code.replacingOccurrences(of: "_", with: " ").capitalized + "."
    }
}

enum FitnessStravaAuthorizationError: LocalizedError {
    case couldNotStart
    case invalidCallback
    case providerRejected

    var errorDescription: String? {
        switch self {
        case .couldNotStart: "Strava sign-in could not be opened."
        case .invalidCallback: "Strava sign-in did not return to HausKlar."
        case .providerRejected: "Strava did not complete the connection. Try again."
        }
    }
}

@MainActor
final class FitnessStravaAuthorizationSession: NSObject,
    FitnessIntervalsAuthorizing,
    ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "hausklar") {
                [weak self] callback, error in
                self?.session = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: FitnessStravaAuthorizationError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: FitnessStravaAuthorizationError.couldNotStart)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
    }
}

@MainActor
final class FitnessStravaViewModel: FitnessViewModelBase {
    @Published private(set) var status: FitnessStravaStatus?
    @Published private(set) var operationMessage: String?
    @Published private(set) var isWorking = false

    private let service: any FitnessStravaServing
    private let authorizationSession: any FitnessIntervalsAuthorizing
    private let ownerContextProvider: () -> FitnessIntervalsOwnerContext?
    private var activeOwner: FitnessIntervalsOwnerContext?

    init(
        service: any FitnessStravaServing = FitnessStravaService.shared,
        authorizationSession: (any FitnessIntervalsAuthorizing)? = nil,
        ownerContextProvider: @escaping () -> FitnessIntervalsOwnerContext? = {
            APIClient.shared.currentSessionSnapshot().map {
                FitnessIntervalsOwnerContext(identity: $0.identity, generation: $0.generation)
            }
        }
    ) {
        self.service = service
        self.authorizationSession = authorizationSession ?? FitnessStravaAuthorizationSession()
        self.ownerContextProvider = ownerContextProvider
        super.init()
    }

    var isConnected: Bool {
        status?.isConnectedIntegration == true
    }

    func load() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        defer { if isCurrent(owner) { isWorking = false } }
        do {
            let response = try await service.loadStatus()
            guard isCurrent(owner) else { return }
            status = response
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func connect() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer { if isCurrent(owner) { isWorking = false } }
        do {
            let start = try await service.startOAuth()
            guard isCurrent(owner),
                  let authorizationURL = ProviderAuthorizationURLPolicy.validatedURL(
                      start.authorizationUrl,
                      provider: .strava
                  ) else {
                throw FitnessStravaAuthorizationError.providerRejected
            }
            let callback = try await authorizationSession.authenticate(at: authorizationURL)
            guard isCurrent(owner) else { return }
            guard let outcome = HausKlarAuthorizationCallback(
                url: callback,
                provider: .strava
            ) else {
                throw FitnessStravaAuthorizationError.invalidCallback
            }
            if outcome == .cancelled {
                operationMessage = "Strava connection cancelled."
                return
            }
            guard outcome == .connected else {
                throw FitnessStravaAuthorizationError.providerRejected
            }
            let response = try await service.loadStatus()
            guard isCurrent(owner) else { return }
            status = response
            operationMessage = "Strava connected. Your latest activities were checked."
            HapticManager.success()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            guard isCurrent(owner) else { return }
            operationMessage = "Strava connection cancelled."
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    @discardableResult
    func syncActivities() async -> Int {
        guard !isWorking, let owner = prepareOwner() else { return 0 }
        let usageRun = UsageMonitor.start(.pullStrava)
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer { if isCurrent(owner) { isWorking = false } }
        do {
            let response = try await service.syncActivities()
            guard isCurrent(owner) else {
                UsageMonitor.cancel(usageRun, interactions: 1)
                return 0
            }
            status = response.status
            let changed = response.importedCount + response.updatedCount
            operationMessage = changed == 0
                ? "Everything from Strava is already here."
                : "\(changed) session\(changed == 1 ? "" : "s") brought in from Strava."
            UsageMonitor.complete(usageRun, interactions: 1)
            HapticManager.success()
            return changed
        } catch {
            guard isCurrent(owner) else {
                UsageMonitor.cancel(usageRun, interactions: 1)
                return 0
            }
            UsageMonitor.fail(usageRun, error: error, interactions: 1)
            errorMessage = error.localizedDescription
            HapticManager.error()
            return 0
        }
    }

    func disconnect() async {
        guard !isWorking, let owner = prepareOwner() else { return }
        isWorking = true
        errorMessage = nil
        operationMessage = nil
        defer { if isCurrent(owner) { isWorking = false } }
        do {
            let response = try await service.disconnect()
            guard isCurrent(owner) else { return }
            status = FitnessStravaStatus(
                configured: true, connected: false, status: response.status,
                athleteName: nil, lastSyncAt: nil, dataThroughAt: nil,
                importedActivityCount: response.retainedActivityCount, lastErrorCode: nil
            )
            operationMessage = "Strava disconnected. Imported sessions remain in your history."
            HapticManager.success()
        } catch {
            guard isCurrent(owner) else { return }
            errorMessage = error.localizedDescription
            HapticManager.error()
        }
    }

    private func prepareOwner() -> FitnessIntervalsOwnerContext? {
        let current = ownerContextProvider()
        guard activeOwner == current else {
            activeOwner = current
            status = nil
            operationMessage = nil
            errorMessage = nil
            isWorking = false
            return current
        }
        return current
    }

    private func isCurrent(_ owner: FitnessIntervalsOwnerContext) -> Bool {
        activeOwner == owner && ownerContextProvider() == owner
    }
}
