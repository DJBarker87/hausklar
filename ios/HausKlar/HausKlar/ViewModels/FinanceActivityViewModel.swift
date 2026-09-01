import AuthenticationServices
import Foundation
import UIKit

enum FinanceBankConnectionOutcome: Equatable, Sendable {
    case connected
    case cancelled
    case failed
}

enum FinanceBankAuthenticationResult: Equatable, Sendable {
    case callback(URL)
    case cancelled
}

private enum FinanceBankConnectionError: Error {
    case invalidAddress
    case couldNotOpen
}

private struct FinanceBankConnectionStartRequest: Encodable {
    let spaceId: String
    let client: String
    let connectionId: String?

    init(spaceId: String, connectionId: String?) {
        self.spaceId = spaceId
        client = "ios"
        self.connectionId = connectionId
    }
}

private struct FinanceBankConnectionStartResponse: Decodable {
    let redirectUrl: String
}

struct FinanceBankConnectionDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let spaceId: String
    let canManage: Bool
    let provider: String
    let institution: String
    let status: String

    var requiresReconnect: Bool {
        ["EXPIRED", "REAUTH_REQUIRED", "DISCONNECTED"].contains(status)
    }

    var isHistoricalReadOnly: Bool {
        requiresReconnect && !canManage
    }

    var canReconnectInApp: Bool {
        canManage && provider == "TRUELAYER" && requiresReconnect
    }

    var statusLabel: String {
        if isHistoricalReadOnly { return "History only".localized }
        switch status {
        case "CONNECTED", "PARTIAL": return "Connected".localized
        case "EXPIRED", "REAUTH_REQUIRED": return "Sign in again".localized
        case "DISCONNECTED": return "Disconnected".localized
        case "PROVIDER_DOWN": return "Temporarily unavailable".localized
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

@MainActor
protocol FinanceBankConnectionAPI {
    func fetchConnections(spaceId: String) async throws -> [FinanceBankConnectionDTO]
    func startBankConnection(spaceId: String, connectionId: String?) async throws -> URL
}

@MainActor
struct LiveFinanceBankConnectionAPI: FinanceBankConnectionAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchConnections(spaceId: String) async throws -> [FinanceBankConnectionDTO] {
        try await client.get(
            "/finance/connections",
            queryItems: [URLQueryItem(name: "space_id", value: spaceId)],
            bypassCache: true
        )
    }

    func startBankConnection(spaceId: String, connectionId: String?) async throws -> URL {
        let response: FinanceBankConnectionStartResponse = try await client.post(
            "/finance/connections/truelayer/start",
            body: FinanceBankConnectionStartRequest(
                spaceId: spaceId,
                connectionId: connectionId
            )
        )
        guard let redirect = URL(string: response.redirectUrl) else {
            throw FinanceBankConnectionError.invalidAddress
        }
        return redirect
    }
}

@MainActor
protocol FinanceBankAuthenticating: AnyObject {
    func authenticate(
        at url: URL,
        callbackURLScheme: String
    ) async throws -> FinanceBankAuthenticationResult
}

@MainActor
final class FinanceBankAuthenticationSession: NSObject,
    FinanceBankAuthenticating,
    ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(
        at url: URL,
        callbackURLScheme: String
    ) async throws -> FinanceBankAuthenticationResult {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme
            ) { [weak self] callback, error in
                self?.session = nil
                if let sessionError = error as? ASWebAuthenticationSessionError,
                   sessionError.code == .canceledLogin {
                    continuation.resume(returning: .cancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let callback {
                    continuation.resume(returning: .callback(callback))
                } else {
                    continuation.resume(throwing: FinanceBankConnectionError.invalidAddress)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: FinanceBankConnectionError.couldNotOpen)
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
protocol FinanceBankConnectionCoordinating {
    func fetchConnections(spaceId: String) async throws -> [FinanceBankConnectionDTO]
    func connect(spaceId: String, connectionId: String?) async -> FinanceBankConnectionOutcome
}

@MainActor
final class FinanceBankConnectionCoordinator: FinanceBankConnectionCoordinating {
    private let api: any FinanceBankConnectionAPI
    private let authenticationSession: any FinanceBankAuthenticating

    init(
        api: (any FinanceBankConnectionAPI)? = nil,
        authenticationSession: (any FinanceBankAuthenticating)? = nil
    ) {
        self.api = api ?? LiveFinanceBankConnectionAPI()
        self.authenticationSession = authenticationSession ?? FinanceBankAuthenticationSession()
    }

    func fetchConnections(spaceId: String) async throws -> [FinanceBankConnectionDTO] {
        try await api.fetchConnections(spaceId: spaceId)
    }

    func connect(
        spaceId: String,
        connectionId: String?
    ) async -> FinanceBankConnectionOutcome {
        do {
            let redirect = try await api.startBankConnection(
                spaceId: spaceId,
                connectionId: connectionId
            )
            guard Self.isAllowedAuthorizationURL(redirect) else { return .failed }

            let authentication = try await authenticationSession.authenticate(
                at: redirect,
                callbackURLScheme: "hausklar"
            )
            switch authentication {
            case .cancelled:
                return .cancelled
            case .callback(let callback):
                return Self.outcome(forCallbackURL: callback) ?? .failed
            }
        } catch {
            return .failed
        }
    }

    static func isAllowedAuthorizationURL(_ url: URL) -> Bool {
        ProviderAuthorizationURLPolicy.allows(url, provider: .trueLayer)
    }

    static func outcome(forCallbackURL url: URL) -> FinanceBankConnectionOutcome? {
        switch HausKlarAuthorizationCallback(url: url, provider: .finance) {
        case .connected: return .connected
        case .cancelled: return .cancelled
        case .failed: return .failed
        case nil: return nil
        }
    }
}

enum FinanceActivityScope: String, CaseIterable, Identifiable, Sendable {
    case mine
    case household

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mine: "Mine".localized
        case .household: "Household".localized
        }
    }

    var webScope: FinanceWebScope {
        switch self {
        case .mine: .mine
        case .household: .household
        }
    }
}

struct FinanceActivitySpaceSnapshot: Identifiable, Equatable, Sendable {
    var id: String { space.id }
    let space: FinanceSpaceDTO
    let accounts: [FinanceAccountSummaryDTO]
    let transactions: [FinanceTransactionDTO]
    let purchaseInbox: [FinancePurchaseEvidenceInboxItemDTO]
    let purchases: [FinancePurchaseRecordDTO]
}

enum FinanceActivityLoadMode: Sendable {
    case activity
    case management
}

@MainActor
protocol FinanceActivityAPI: Sendable {
    func fetchSpaces(forceRefresh: Bool) async throws -> [FinanceSpaceDTO]
    func fetchAccounts(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinanceAccountSummaryDTO]
    func fetchTransactions(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinanceTransactionDTO]
    func fetchPurchaseInbox(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinancePurchaseEvidenceInboxItemDTO]
    func fetchPurchases(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinancePurchaseRecordDTO]
    func fetchPurchase(id: String, forceRefresh: Bool) async throws -> FinancePurchaseRecordDTO
}

struct LiveFinanceActivityAPI: FinanceActivityAPI {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchSpaces(forceRefresh: Bool) async throws -> [FinanceSpaceDTO] {
        try await client.get("/finance/spaces", bypassCache: forceRefresh)
    }

    func fetchAccounts(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinanceAccountSummaryDTO] {
        try await client.get(
            "/finance/accounts",
            queryItems: Self.spaceQuery(
                spaceId: spaceId,
                excludeOwnSharedCopies: excludeOwnSharedCopies
            ),
            bypassCache: forceRefresh
        )
    }

    func fetchTransactions(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinanceTransactionDTO] {
        var query = Self.spaceQuery(
            spaceId: spaceId,
            excludeOwnSharedCopies: excludeOwnSharedCopies
        )
        query.append(URLQueryItem(name: "limit", value: "20"))
        return try await client.get(
            "/finance/transactions",
            queryItems: query,
            bypassCache: forceRefresh
        )
    }

    func fetchPurchaseInbox(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinancePurchaseEvidenceInboxItemDTO] {
        var query = Self.spaceQuery(
            spaceId: spaceId,
            excludeOwnSharedCopies: excludeOwnSharedCopies
        )
        query.append(URLQueryItem(name: "limit", value: "20"))
        return try await client.get(
            "/finance/purchases/inbox",
            queryItems: query,
            bypassCache: forceRefresh
        )
    }

    func fetchPurchases(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinancePurchaseRecordDTO] {
        var query = Self.spaceQuery(
            spaceId: spaceId,
            excludeOwnSharedCopies: excludeOwnSharedCopies
        )
        query.append(URLQueryItem(name: "limit", value: "10"))
        return try await client.get(
            "/finance/purchases",
            queryItems: query,
            bypassCache: forceRefresh
        )
    }

    func fetchPurchase(id: String, forceRefresh: Bool) async throws -> FinancePurchaseRecordDTO {
        return try await client.get(
            "/finance/purchases/\(id)",
            bypassCache: forceRefresh
        )
    }

    private static func spaceQuery(
        spaceId: String,
        excludeOwnSharedCopies: Bool
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "space_id", value: spaceId),
            URLQueryItem(
                name: "exclude_own_shared_copies",
                value: excludeOwnSharedCopies ? "true" : "false"
            ),
        ]
    }
}

@MainActor
final class FinanceActivityViewModel: ObservableObject {
    @Published private(set) var scope: FinanceActivityScope
    @Published private(set) var snapshots: [FinanceActivitySpaceSnapshot] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isConnectingBank = false
    @Published private(set) var isLoadingBankConnections = false
    @Published private(set) var bankConnections: [FinanceBankConnectionDTO] = []
    @Published private(set) var bankConnectionsUnavailable = false
    @Published private(set) var bankConnectionMessage: String?
    @Published var errorMessage: String?

    private let api: FinanceActivityAPI
    private let bankConnectionCoordinator: any FinanceBankConnectionCoordinating
    private let loadMode: FinanceActivityLoadMode

    init(
        initialScope: FinanceActivityScope = .mine,
        loadMode: FinanceActivityLoadMode = .management,
        api: FinanceActivityAPI? = nil,
        bankConnectionCoordinator: (any FinanceBankConnectionCoordinating)? = nil
    ) {
        scope = initialScope
        self.loadMode = loadMode
        self.api = api ?? LiveFinanceActivityAPI()
        self.bankConnectionCoordinator = bankConnectionCoordinator ?? FinanceBankConnectionCoordinator()
    }

    var isInitialLoading: Bool {
        isLoading && snapshots.isEmpty
    }

    var bankConnectionSpaceId: String? {
        guard loadMode == .management else { return nil }
        switch scope {
        case .mine:
            return snapshots.first(where: {
                $0.space.isDefault
                    && $0.space.kind.localizedCaseInsensitiveCompare("personal") == .orderedSame
            })?.space.id
        case .household:
            return snapshots.first(where: {
                $0.space.kind.localizedCaseInsensitiveCompare("household") == .orderedSame
            })?.space.id
        }
    }

    func selectScope(_ newScope: FinanceActivityScope) async {
        guard scope != newScope else { return }
        scope = newScope
        snapshots = []
        bankConnections = []
        bankConnectionsUnavailable = false
        bankConnectionMessage = nil
        await load(forceRefresh: true)
    }

    func connectBank(spaceId: String, connectionId: String? = nil) async {
        guard !isLoading,
              !isConnectingBank,
              bankConnectionSpaceId == spaceId else {
            return
        }
        if let connectionId {
            guard bankConnections.contains(where: {
                $0.id == connectionId
                    && $0.spaceId == spaceId
                    && $0.canReconnectInApp
            }) else {
                return
            }
        } else if bankConnections.contains(where: \.canReconnectInApp) {
            // Reauthorise the saved row instead of starting a second connection.
            return
        }
        let requestedScope = scope
        isConnectingBank = true
        bankConnectionMessage = nil
        defer { isConnectingBank = false }

        let outcome = await bankConnectionCoordinator.connect(
            spaceId: spaceId,
            connectionId: connectionId
        )
        guard scope == requestedScope else { return }
        switch outcome {
        case .cancelled:
            return
        case .failed:
            bankConnectionMessage = "Couldn’t connect the bank. Try again.".localized
            HapticManager.error()
        case .connected:
            let refreshed = await refreshConnectedSpace(
                spaceId: spaceId,
                requestedScope: requestedScope
            )
            _ = await loadBankConnections(spaceId: spaceId, preserveExisting: true)
            guard scope == requestedScope else { return }
            bankConnectionMessage = refreshed
                ? "Bank connected.".localized
                : "Bank connected. Pull down to update accounts.".localized
            HapticManager.success()
        }
    }

    func retryBankConnections(spaceId: String) async {
        guard !isLoadingBankConnections,
              !isConnectingBank,
              bankConnectionSpaceId == spaceId else {
            return
        }
        _ = await loadBankConnections(spaceId: spaceId, preserveExisting: true)
    }

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        let requestedScope = scope
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let spaces = try await api.fetchSpaces(forceRefresh: forceRefresh)
            let visibleSpaces = Self.visibleSpaces(for: requestedScope, from: spaces)
            guard !visibleSpaces.isEmpty else {
                if scope == requestedScope {
                    snapshots = []
                    bankConnections = []
                    bankConnectionsUnavailable = false
                    errorMessage = "This Finance space is not available to your account.".localized
                }
                return
            }

            var loaded: [FinanceActivitySpaceSnapshot] = []
            var failures = 0
            for space in visibleSpaces {
                do {
                    loaded.append(
                        try await loadSnapshot(
                            for: space,
                            requestedScope: requestedScope,
                            forceRefresh: forceRefresh
                        )
                    )
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                }
            }

            guard scope == requestedScope else { return }
            snapshots = loaded
            if let spaceId = bankConnectionSpaceId {
                _ = await loadBankConnections(spaceId: spaceId, preserveExisting: false)
            } else {
                bankConnections = []
                bankConnectionsUnavailable = false
            }
            if failures > 0 {
                errorMessage = loaded.isEmpty
                    ? "Finance could not load. Check your connection and try again.".localized
                    : "Part of Finance could not load. You can still use what is shown.".localized
            }
        } catch is CancellationError {
            return
        } catch {
            guard scope == requestedScope else { return }
            errorMessage = Self.message(for: error)
        }
    }

    static func visibleSpaces(
        for scope: FinanceActivityScope,
        from spaces: [FinanceSpaceDTO]
    ) -> [FinanceSpaceDTO] {
        let household = spaces.first(where: { isHousehold($0) })
        if scope == .household {
            return household.map { [$0] } ?? []
        }

        // The server marks only the signed-in adult's personal space as default.
        // Failing closed here prevents an unexpected second personal space being read.
        let personal = spaces.first(where: {
            $0.isDefault && $0.kind.localizedCaseInsensitiveCompare("personal") == .orderedSame
        })
        return [personal, household].compactMap { $0 }
    }

    private static func isHousehold(_ space: FinanceSpaceDTO) -> Bool {
        space.kind.localizedCaseInsensitiveCompare("household") == .orderedSame
    }

    private func loadBankConnections(
        spaceId: String,
        preserveExisting: Bool
    ) async -> Bool {
        guard bankConnectionSpaceId == spaceId else { return false }
        isLoadingBankConnections = true
        bankConnectionsUnavailable = false
        defer { isLoadingBankConnections = false }

        do {
            let loaded = try await bankConnectionCoordinator.fetchConnections(spaceId: spaceId)
            guard bankConnectionSpaceId == spaceId else { return false }
            bankConnections = loaded
                .filter { $0.spaceId == spaceId }
                .sorted {
                    $0.institution.localizedCaseInsensitiveCompare($1.institution) == .orderedAscending
                        || ($0.institution == $1.institution && $0.id < $1.id)
                }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard bankConnectionSpaceId == spaceId else { return false }
            if !preserveExisting { bankConnections = [] }
            bankConnectionsUnavailable = true
            return false
        }
    }

    private func refreshConnectedSpace(
        spaceId: String,
        requestedScope: FinanceActivityScope
    ) async -> Bool {
        guard let current = snapshots.first(where: { $0.space.id == spaceId }) else {
            return false
        }
        let space = current.space

        do {
            let refreshed = try await loadSnapshot(
                for: space,
                requestedScope: requestedScope,
                forceRefresh: true
            )
            guard scope == requestedScope,
                  let index = snapshots.firstIndex(where: { $0.space.id == spaceId }) else {
                return false
            }
            snapshots[index] = refreshed
            return true
        } catch is CancellationError {
            return false
        } catch {
            return false
        }
    }

    private func loadSnapshot(
        for space: FinanceSpaceDTO,
        requestedScope: FinanceActivityScope,
        forceRefresh: Bool
    ) async throws -> FinanceActivitySpaceSnapshot {
        // In My finances the personal record is already shown, so omit that
        // adult's shared copy from the separate Household section.
        let excludeOwnSharedCopies = requestedScope == .mine && Self.isHousehold(space)
        async let accounts = api.fetchAccounts(
            spaceId: space.id,
            excludeOwnSharedCopies: excludeOwnSharedCopies,
            forceRefresh: forceRefresh
        )
        async let transactions = api.fetchTransactions(
            spaceId: space.id,
            excludeOwnSharedCopies: excludeOwnSharedCopies,
            forceRefresh: forceRefresh
        )

        let managementValues: (
            [FinancePurchaseEvidenceInboxItemDTO],
            [FinancePurchaseRecordDTO]
        )
        if loadMode == .management {
            async let inbox = api.fetchPurchaseInbox(
                spaceId: space.id,
                excludeOwnSharedCopies: excludeOwnSharedCopies,
                forceRefresh: forceRefresh
            )
            async let purchases = api.fetchPurchases(
                spaceId: space.id,
                excludeOwnSharedCopies: excludeOwnSharedCopies,
                forceRefresh: forceRefresh
            )
            managementValues = try await (inbox, purchases)
        } else {
            managementValues = ([], [])
        }

        let activityValues = try await (accounts, transactions)
        return FinanceActivitySpaceSnapshot(
            space: space,
            accounts: activityValues.0.sorted {
                $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            },
            transactions: activityValues.1.sorted { $0.canonicalDate > $1.canonicalDate },
            purchaseInbox: managementValues.0
                .filter { $0.status == "OPEN" }
                .sorted {
                    if $0.priority != $1.priority { return $0.priority > $1.priority }
                    return $0.createdAt > $1.createdAt
                },
            purchases: managementValues.1.sorted { $0.purchasedOn > $1.purchasedOn }
        )
    }

    private static func message(for error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .networkError:
                return "Finance needs an internet connection. Reconnect and try again.".localized
            default:
                return apiError.errorDescription ?? "Finance could not load. Try again.".localized
            }
        }
        return "Finance could not load. Check your connection and try again.".localized
    }
}

@MainActor
final class FinancePurchaseDetailViewModel: ObservableObject {
    @Published private(set) var purchase: FinancePurchaseRecordDTO?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let purchaseId: String
    private let api: FinanceActivityAPI

    init(purchaseId: String, api: FinanceActivityAPI? = nil) {
        self.purchaseId = purchaseId
        self.api = api ?? LiveFinanceActivityAPI()
    }

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            purchase = try await api.fetchPurchase(id: purchaseId, forceRefresh: forceRefresh)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "This purchase could not be loaded. Check your connection and try again.".localized
        }
    }
}
