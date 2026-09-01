import XCTest
import Security
import SwiftData
import CryptoKit
@testable import HausKlar

/// Tests for APIClient configuration: singleton identity, base URL, and
/// JSON coding strategies (convertToSnakeCase / convertFromSnakeCase).
final class APIClientTests: XCTestCase {
    /// Mutable callback state used by sendable test doubles. Every access is
    /// serialized so the tests exercise ordering without data races.
    private final class LockedTestValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            storage = value
        }

        func read() -> Value {
            lock.withLock { storage }
        }

        func set(_ value: Value) {
            lock.withLock { storage = value }
        }

        @discardableResult
        func update<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.withLock { body(&storage) }
        }
    }

    /// A one-shot suspension point for cache-race tests. Actor isolation keeps
    /// continuation publication and resumption ordered without captured vars.
    private actor TestAsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    func testAuthenticatedRedirectPolicyPreservesBearerForSameHTTPSOrigin() throws {
        var original = URLRequest(url: try XCTUnwrap(URL(string: "https://API.Example.com/api/items")))
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        let proposed = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com:443/api/items/")))

        let redirected = try XCTUnwrap(
            AuthenticatedRedirectPolicy.redirectedRequest(original: original, proposed: proposed)
        )

        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-token"
        )
    }

    func testAuthenticatedRedirectPolicyRejectsDowngradeCrossHostAndCrossPort() throws {
        var original = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/api")))
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")

        for value in [
            "http://api.example.com/api/",
            "https://other.example.com/api/",
            "https://api.example.com:444/api/",
        ] {
            let proposed = URLRequest(url: try XCTUnwrap(URL(string: value)))
            XCTAssertNil(
                AuthenticatedRedirectPolicy.redirectedRequest(
                    original: original,
                    proposed: proposed
                ),
                value
            )
        }
    }

    func testAuthenticatedRedirectPolicyRejectsUserInfoAndAmbiguousHosts() throws {
        var original = URLRequest(url: try XCTUnwrap(URL(string: "https://api.example.com/api")))
        original.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        for value in [
            "https://demo-person-29@example.invalid/api/",
            "https://api.example.com%2eevil.example/api/",
            "https://demo-person-4@example.invalid/api/",
        ] {
            guard let url = URL(string: value) else { continue }
            XCTAssertNil(
                AuthenticatedRedirectPolicy.redirectedRequest(
                    original: original,
                    proposed: URLRequest(url: url)
                ),
                value
            )
        }
    }

    func testAuthenticatedRedirectPolicyRejectsLoginAndRefreshBodyCrossOriginRedirects() throws {
        for path in ["/auth/login", "/auth/refresh"] {
            var original = URLRequest(
                url: try XCTUnwrap(URL(string: "https://api.example.com\(path)"))
            )
            original.httpMethod = "POST"
            original.httpBody = Data("sensitive-credential".utf8)
            for target in [
                "https://evil.example/collect",
                "http://api.example.com/collect",
                "https://api.example.com:444/collect",
            ] {
                XCTAssertNil(
                    AuthenticatedRedirectPolicy.redirectedRequest(
                        original: original,
                        proposed: URLRequest(url: try XCTUnwrap(URL(string: target)))
                    ),
                    "\(path) -> \(target)"
                )
            }
        }
    }

    func testAuthenticatedRedirectPolicyAllowsSameOriginCredentialBodyRedirect() throws {
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example.com/auth/login"))
        )
        original.httpMethod = "POST"
        original.httpBody = Data("credential".utf8)
        let proposed = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example.com:443/auth/login/"))
        )
        XCTAssertEqual(
            AuthenticatedRedirectPolicy.redirectedRequest(
                original: original,
                proposed: proposed
            )?.url,
            proposed.url
        )
    }

    func testSafeDownloadFilenameRejectsTraversalControlsAndDirectoryNames() {
        XCTAssertEqual(APIClient.safeDownloadFilename("family-export.zip"), "family-export.zip")
        XCTAssertEqual(APIClient.safeDownloadFilename("../../secret.zip"), "download.zip")
        XCTAssertEqual(APIClient.safeDownloadFilename("..\\secret.fit"), "download.fit")
        XCTAssertEqual(APIClient.safeDownloadFilename("\u{0}bad.zip"), "download.zip")
        XCTAssertEqual(APIClient.safeDownloadFilename("."), "download")
        XCTAssertEqual(APIClient.safeDownloadFilename(".."), "download")
        XCTAssertEqual(APIClient.safeDownloadFilename(".hidden"), "download.hidden")
        XCTAssertEqual(APIClient.safeDownloadFilename(""), "download")
    }

    func testInvalidInitialAPIOriginsFailBeforeIdentityBodyAndTransport() async {
        let identityResolutions = LockedTestValue(0)
        let encodes = LockedTestValue(0)
        let transports = LockedTestValue(0)
        APIClientStubURLProtocol.install { _ in
            transports.update { $0 += 1 }
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: {
                identityResolutions.update { $0 += 1 }
                return "00000000-0000-4000-8000-000000000001"
            }
        )
        defer { client.clearSession() }

        for invalidBaseURL in [
            "http://api.example.test/api",
            "https://user:demo-person-14@example.invalid/api",
            "https:///api",
            "https://api.example.test:0/api",
            "https://api.example.test:65536/api",
            "https://api.example.test/api#credential-fragment",
            " https://api.example.test/api",
        ] {
            client.baseURL = invalidBaseURL
            do {
                try await client.postNoResponse(
                    "/tasks",
                    body: EncodingProbe { encodes.update { $0 += 1 } }
                )
                XCTFail("Expected an invalid URL for \(invalidBaseURL)")
            } catch APIError.invalidURL {
                // Expected before any sensitive request state is assembled.
            } catch {
                XCTFail("Expected invalidURL for \(invalidBaseURL), got \(error)")
            }
        }

        client.baseURL = "https://api.example.test/api"
        for invalidValue in ["//evil.example/collect", "/tasks#sensitive-fragment"] {
            let invalidPath = APIRequestPath(stringLiteral: invalidValue)
            do {
                try await client.postNoResponse(
                    invalidPath,
                    body: EncodingProbe { encodes.update { $0 += 1 } }
                )
                XCTFail("An ambiguous API path must be rejected: \(invalidValue)")
            } catch APIError.invalidURL {
                // Expected.
            } catch {
                XCTFail("Expected invalidURL for \(invalidValue), got \(error)")
            }
        }

        XCTAssertEqual(identityResolutions.read(), 0)
        XCTAssertEqual(encodes.read(), 0)
        XCTAssertEqual(transports.read(), 0)
    }

    func testDynamicPathSegmentIsEncodedOnceAndQueryItemsStayStructural() async throws {
        let lock = NSLock()
        var receivedURL: URL?
        let client = makeStubbedClient { request in
            lock.withLock { receivedURL = request.url }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"value":"ok"}"#.utf8)
            )
        }
        defer { client.clearSession() }

        let dynamicID = "Müller & Sons"
        let _: CachedResponse = try await client.get(
            "/documents/\(dynamicID)/content",
            queryItems: [URLQueryItem(name: "size", value: "thumb & private")],
            cachePolicy: .networkOnly
        )

        let components = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(lock.withLock { receivedURL }),
                resolvingAgainstBaseURL: false
            )
        )
        XCTAssertEqual(
            components.percentEncodedPath,
            "/api/documents/M%C3%BCller%20%26%20Sons/content"
        )
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "size", value: "thumb & private")]
        )
    }

    func testAuthenticatedDownloadKeepsQueryItemsOutOfTypedPath() async throws {
        let lock = NSLock()
        var receivedURL: URL?
        let payload = Data("bounded image".utf8)
        let client = makeStubbedClient { request in
            lock.withLock { receivedURL = request.url }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/jpeg"]
                )!,
                payload
            )
        }
        defer { client.clearSession() }

        let assetID = "child photo 1"
        let data = try await client.downloadData(
            "/photos/\(assetID)/thumbnail",
            policy: opaqueJPEGPolicy,
            cachePolicy: .networkOnly,
            queryItems: [URLQueryItem(name: "size", value: "800")]
        )

        XCTAssertEqual(data, payload)
        let components = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(lock.withLock { receivedURL }),
                resolvingAgainstBaseURL: false
            )
        )
        XCTAssertEqual(
            components.percentEncodedPath,
            "/api/photos/child%20photo%201/thumbnail"
        )
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "size", value: "800")])
    }

    func testInvalidDynamicPathSegmentFailsBeforeTransport() async {
        let lock = NSLock()
        var transports = 0
        let client = makeStubbedClient { request in
            lock.withLock { transports += 1 }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"value":"unexpected"}"#.utf8)
            )
        }
        defer { client.clearSession() }

        let injectedID = "record/../../auth/me?admin=true"
        do {
            let _: CachedResponse = try await client.get(
                "/documents/\(injectedID)",
                cachePolicy: .networkOnly
            )
            XCTFail("A dynamic value must not be able to alter route structure")
        } catch APIError.invalidURL {
            // Expected before URLSession sees a request.
        } catch {
            XCTFail("Expected invalidURL, got \(error)")
        }
        XCTAssertEqual(lock.withLock { transports }, 0)
    }

    func testCanonicalAPIOriginNormalizesDefaultPortAndRetainsAllowedExactPort() async throws {
        let lock = NSLock()
        var receivedURLs: [URL] = []
        let client = makeStubbedClient { request in
            lock.withLock {
                if let url = request.url { receivedURLs.append(url) }
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { client.clearSession() }

        client.baseURL = "HTTPS://API.Example.Test.:443/api/"
        try await client.postNoResponse("/tasks", body: EmptyBody())
        client.baseURL = "https://api.example.test:8443/api"
        try await client.postNoResponse("/tasks", body: EmptyBody())

        let urls = lock.withLock { receivedURLs }
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].scheme, "https")
        XCTAssertEqual(urls[0].host, "api.example.test")
        XCTAssertNil(urls[0].port)
        XCTAssertEqual(urls[0].path, "/api/tasks")
        XCTAssertEqual(urls[1].scheme, "https")
        XCTAssertEqual(urls[1].host, "api.example.test")
        XCTAssertEqual(urls[1].port, 8443)
        XCTAssertEqual(urls[1].path, "/api/tasks")
    }

    func testOfflineFlushAckSaveFailureReplaysStableOperationInsteadOfDeadLettering() async throws {
        enum InjectedFailure: Error { case acknowledgement }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineFlushAck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saveLock = NSLock()
        var saveCount = 0
        let store = OfflineHTTPMutationStore(
            directory: directory,
            maxEncodedBytes: 20_000,
            saveHook: {
                let count = saveLock.withLock { () -> Int in
                    saveCount += 1
                    return saveCount
                }
                if count == 3 { throw InjectedFailure.acknowledgement }
            }
        )
        let identity = "family:user"
        let operationID = "stable-operation-id"
        try await store.enqueue(
            QueuedHTTPMutation(
                id: operationID,
                identity: identity,
                method: "POST",
                path: "/dog/activities",
                body: Data(#"{"kind":"walk"}"#.utf8),
                contentType: "application/json",
                createdAt: Date()
            )
        )
        let requestLock = NSLock()
        var receivedOperationIDs: [String] = []
        APIClientStubURLProtocol.install { request in
            requestLock.withLock {
                receivedOperationIDs.append(
                    request.value(forHTTPHeaderField: "X-HausKlar-Operation-ID") ?? ""
                )
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" },
            offlineMutationStore: store
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: identity,
            accessToken: "access",
            refreshToken: "refresh"
        )
        defer { client.clearSession() }

        await client.flushOfflineMutations()

        var summaries = try await store.summaries(identity: identity)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].status, .pending)
        XCTAssertEqual(summaries[0].retryCount, 0)

        await client.flushOfflineMutations()

        summaries = try await store.summaries(identity: identity)
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertEqual(
            requestLock.withLock { receivedOperationIDs },
            [operationID, operationID]
        )
    }

    func testOfflineTokenRefreshFailurePreservesSessionWithoutAuthCallback() async throws {
        let userJSON = #"{"id":"user","family_id":"family"}"#
        let originalEnvelope = StoredSessionEnvelope(
            identity: "family:user",
            accessToken: "expired-access",
            refreshToken: "long-lived-refresh",
            userJSON: userJSON
        )
        let storedEnvelope = LockedTestValue(originalEnvelope)
        APIClientStubURLProtocol.install { request in
            if request.url?.path == "/api/auth/refresh" {
                throw URLError(.notConnectedToInternet)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"expired"}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            loadSessionEnvelope: { storedEnvelope.read() },
            saveSessionEnvelope: { storedEnvelope.set($0) }
        )
        client.baseURL = "https://api.example.test/api"
        let originalSession = client.installSession(
            identity: originalEnvelope.identity,
            accessToken: originalEnvelope.accessToken,
            refreshToken: originalEnvelope.refreshToken,
            persistTokenRotation: true
        )
        let callbackCount = LockedTestValue(0)
        client.onAuthFailure = { _ in callbackCount.update { $0 += 1 } }
        defer { client.clearSession() }

        do {
            let _: CachedResponse = try await client.get(
                "/tasks/refresh-offline-\(UUID().uuidString)",
                cachePolicy: .networkOnly
            )
            XCTFail("The offline refresh should surface its transport error")
        } catch APIError.networkError {
            // Expected: this is retryable connectivity, not session expiry.
        }

        XCTAssertEqual(client.currentSessionSnapshot(), originalSession)
        XCTAssertEqual(storedEnvelope.read(), originalEnvelope)
        XCTAssertEqual(callbackCount.read(), 0)
    }

    func testRefreshServerFailureIsRetryableAndDoesNotTriggerAuthCallback() async throws {
        let originalEnvelope = StoredSessionEnvelope(
            identity: "family:user",
            accessToken: "expired-access",
            refreshToken: "long-lived-refresh",
            userJSON: #"{"id":"user"}"#
        )
        APIClientStubURLProtocol.install { request in
            let status = request.url?.path == "/api/auth/refresh" ? 503 : 401
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"detail":"temporarily unavailable"}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            loadSessionEnvelope: { originalEnvelope },
            saveSessionEnvelope: { _ in XCTFail("A failed refresh must not replace the envelope") }
        )
        client.baseURL = "https://api.example.test/api"
        let originalSession = client.installSession(
            identity: originalEnvelope.identity,
            accessToken: originalEnvelope.accessToken,
            refreshToken: originalEnvelope.refreshToken,
            persistTokenRotation: true
        )
        let callbackCount = LockedTestValue(0)
        client.onAuthFailure = { _ in callbackCount.update { $0 += 1 } }
        defer { client.clearSession() }

        do {
            let _: CachedResponse = try await client.get(
                "/tasks/refresh-server-\(UUID().uuidString)",
                cachePolicy: .networkOnly
            )
            XCTFail("The refresh should surface the upstream server error")
        } catch APIError.serverError(let statusCode, _) {
            XCTAssertEqual(statusCode, 503)
        }

        XCTAssertEqual(client.currentSessionSnapshot(), originalSession)
        XCTAssertEqual(callbackCount.read(), 0)
    }
    @MainActor
    private func identityHarness() throws -> (ModelContainer, ModelContext, UserDefaults) {
        let schema = Schema(versionedSchema: HausKlarSchemaV5.self)
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let suiteName = "HausKlarTests.Identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (container, context, defaults)
    }

    /// AppState authentication tests must not depend on simulator Keychain or
    /// app-group availability. Each state gets an isolated envelope, a durable
    /// test client ID, and a no-I/O shared-capture lifecycle boundary.
    @MainActor
    @discardableResult
    private func configureInMemoryAppStateSession(
        _ state: AppState,
        initialEnvelope: StoredSessionEnvelope? = nil
    ) -> LockedTestValue<StoredSessionEnvelope?> {
        let envelope = LockedTestValue<StoredSessionEnvelope?>(initialEnvelope)
        state.configureSessionEnvelopeStore(
            load: { envelope.read() },
            save: { envelope.set($0) },
            delete: { envelope.set(nil) }
        )
        state.configureClientIdentityRequirement {
            "00000000-0000-4000-8000-000000000001"
        }
        state.configureSharedCaptureIdentityActivation { _ in }
        state.configurePendingFITIdentityActivation { _ in }
        return envelope
    }

    /// Keeps account-boundary tests independent of simulator App Group support
    /// while still deleting every local record/file those tests create.
    @MainActor
    private func configureInMemoryLocalIdentityBoundary(
        _ state: AppState,
        modelContext: ModelContext,
        defaults: UserDefaults
    ) {
        state.configureLocalIdentityBoundary(
            modelContext: modelContext,
            defaults: defaults,
            purge: { modelContext, defaults in
                let fitnessIdentity = defaults.string(forKey: AppState.localOwnerKey)
                try DocumentCaptureService.purgePendingUploadsSecurely()
                if let fitnessIdentity {
                    try FitnessDatabase.shared.deleteStore(
                        identity: fitnessIdentity,
                        legacyOwnerProof: fitnessIdentity
                    )
                }
                try LocalIdentityDataPurger.purgeRecords(modelContext)
                DocumentCaptureService.purgeTemporaryCaptures()
                DocumentPreviewStore.purgeAll()
            }
        )
    }

    private func restoreSharedClientSession(_ session: APIClient.SessionSnapshot?) {
        if let session {
            APIClient.shared.installSession(
                identity: session.identity,
                accessToken: session.accessToken,
                refreshToken: session.refreshToken
            )
        } else {
            APIClient.shared.clearSession()
        }
    }

    func testCalendarEventDecodesParticipantsAndAffectedAdults() throws {
        let json = #"{"id":"event-1","title":"Doctor","description":null,"start_time":"2026-07-15T10:00:00Z","end_time":null,"all_day":false,"recurrence_rule":null,"location":null,"family_member_ids":["kat","child-1"],"affected_member_ids":["dom"],"created_at":"2026-07-13T20:00:00Z","updated_at":"2026-07-13T20:00:00Z","created_by":"kat","assigned_to":null}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let event = try decoder.decode(CalendarEventDTO.self, from: Data(json.utf8))

        XCTAssertEqual(event.familyMemberIds ?? [], ["kat", "child-1"])
        XCTAssertEqual(event.affectedMemberIds ?? [], ["dom"])
        XCTAssertNil(event.assignedTo)
    }

    func testCalendarEventDecodesRugbyVenuePresentation() throws {
        let json = ##"{"id":"rugby-1","title":"AWAY — Colts C rugby v Marlborough College","description":null,"start_time":"2026-10-17T12:00:00Z","end_time":"2026-10-17T18:00:00Z","all_day":false,"recurrence_rule":null,"location":"AWAY","family_member_ids":["dom"],"affected_member_ids":["kat"],"created_at":"2026-08-12T10:00:00Z","updated_at":"2026-08-12T10:00:00Z","created_by":"dom","assigned_to":"dom","event_type":"rugby_fixture","source_color":"#DC2626","rugby_venue":"away","rugby_venue_overridden":true,"read_only":true}"##
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let event = try decoder.decode(CalendarEventDTO.self, from: Data(json.utf8))

        XCTAssertEqual(event.rugbyVenue, "away")
        XCTAssertEqual(event.rugbyVenueOverridden, true)
        XCTAssertEqual(event.sourceColor, "#DC2626")
        XCTAssertEqual(event.affectedMemberIds, ["kat"])
    }

    func testCalendarEventDecodesOriginalDocumentAttachment() throws {
        let json = #"{"id":"event-1","title":"Doctor","description":null,"start_time":"2026-07-15T10:00:00Z","end_time":null,"all_day":false,"recurrence_rule":null,"location":null,"family_member_ids":null,"affected_member_ids":null,"created_at":"2026-07-13T20:00:00Z","updated_at":"2026-07-13T20:00:00Z","created_by":"kat","assigned_to":null,"source_document_id":"doc-1","source_document":{"id":"doc-1","title":"Appointment letter","original_filename":"letter.pdf","media_type":"application/pdf","file_size":1234,"download_url":"/api/documents/doc-1/content"}}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let event = try decoder.decode(CalendarEventDTO.self, from: Data(json.utf8))

        XCTAssertEqual(event.sourceDocumentId, "doc-1")
        XCTAssertEqual(event.sourceDocument?.title, "Appointment letter")
        XCTAssertEqual(event.sourceDocument?.originalFilename, "letter.pdf")
    }

    func testBabysitterIncompleteCaregiverPackDecodesAsNotConfigured() throws {
        let json = #"{"caregiver_pack":{"status":"incomplete","missing_sections":["daily_routine","emergency_contacts","wifi_password","house_rules","allergies"],"daily_routine":null,"emergency_contacts":[],"important_info":null},"children":[],"medicine_schedule":[],"active_naps":[],"todays_events":[]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(BabysitterDataDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.caregiverPack.status, .incomplete)
        XCTAssertEqual(
            response.caregiverPack.missingSections,
            [.dailyRoutine, .emergencyContacts, .wifiPassword, .houseRules, .allergies]
        )
        XCTAssertNil(response.caregiverPack.dailyRoutine)
        XCTAssertTrue(response.caregiverPack.emergencyContacts.isEmpty)
        XCTAssertNil(response.caregiverPack.importantInfo)
        XCTAssertFalse(response.caregiverPack.isConfigured)
    }

    func testBabysitterPackRequiresStatusAndCompleteData() throws {
        let json = #"{"caregiver_pack":{"status":"configured","missing_sections":[],"daily_routine":{"breakfast":"08:00","lunch":"12:00","dinner":"17:30","nap_time":"13:00","bath":"18:30","stories":"19:00","bedtime":"19:30"},"emergency_contacts":[{"name":"Parent","phone":"+00000000002"}],"important_info":{"wifi_password":"family-entered","house_rules":"family-entered","allergies":"family-entered"}},"children":[],"medicine_schedule":[],"active_naps":[],"todays_events":[]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(BabysitterDataDTO.self, from: Data(json.utf8))

        XCTAssertTrue(response.caregiverPack.isConfigured)
    }

    func testAuthoritativeCaregiverHandoverDecodesReadinessAndChildDetail() throws {
        let json = #"{"id":"handover-1","house":{"id":"handover-1","address":"1 Family Road","wifi_name":"HausKlar","wifi_password":"family-entered","emergency_instructions":"Call us first","house_instructions":"Back door key","dog_instructions":"Already fed"},"children":[{"id":"profile-1","child_id":"child-1","child_name":"Child One","care_notes":"Inhaler nearby","allergies":"None known","food":"Toast","comfort":"Blue rabbit","toileting":"Prompt before bed","bedtime":"Two stories"}],"contacts":[{"id":"contact-1","name":"Alex","phone":"+00000000004","relationship":"Dad","priority":0}],"readiness":{"ready":true,"complete_count":11,"total_count":11,"items":[{"key":"address","label":"Home address","ready":true,"child_id":null}]},"updated_at":"2026-08-09T12:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let handover = try decoder.decode(CaregiverHandoverDTO.self, from: Data(json.utf8))

        XCTAssertTrue(handover.readiness.ready)
        XCTAssertEqual(handover.children.first?.childId, "child-1")
        XCTAssertEqual(handover.children.first?.allergies, "None known")
        XCTAssertEqual(handover.house.wifiPassword, "family-entered")
        XCTAssertEqual(handover.contacts.first?.relationship, "Dad")
    }

    func testCreatedCaregiverBookingKeepsBootstrapSecretInURLFragment() throws {
        let json = #"{"id":"booking-1","label":"Saturday evening","starts_at":"2030-08-10T17:00:00Z","expires_at":"2030-08-10T22:00:00Z","child_ids":["child-1"],"child_names":["Child One"],"status":"upcoming","created_at":"2026-08-09T12:00:00Z","revoked_at":null,"last_accessed_at":null,"share_url":"https://hausklar.example/?caregiver=1#invite=one-time-secret"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let booking = try decoder.decode(CaregiverCreatedBookingDTO.self, from: Data(json.utf8))
        let components = try XCTUnwrap(booking.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })

        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "caregiver" })?.value, "1")
        XCTAssertEqual(components.fragment, "invite=one-time-secret")
        XCTAssertFalse(components.percentEncodedQuery?.contains("one-time-secret") ?? true)
        XCTAssertEqual(booking.booking.childNames, ["Child One"])
    }


    // MARK: - Singleton

    func testSharedIsSingleton() {
        let a = APIClient.shared
        let b = APIClient.shared
        XCTAssertTrue(a === b, "APIClient.shared must return the same instance")
    }

    // MARK: - Base URL

    func testBaseURLIsProduction() {
        XCTAssertEqual(
            APIClient.shared.baseURL,
            "http://localhost:8001/api",
            "baseURL should point to the production API"
        )
    }

    // MARK: - JSON Coding Strategies

    /// A simple Codable struct with camelCase properties, used to verify
    /// that the encoder converts to snake_case and the decoder converts back.
    private struct TestPayload: Codable, Equatable {
        let firstName: String
        let lastName: String
        let dateOfBirth: String
    }

    private struct EncodingProbe: Encodable {
        let onEncode: () -> Void

        func encode(to encoder: Encoder) throws {
            onEncode()
            var container = encoder.singleValueContainer()
            try container.encode(true)
        }
    }

    private struct CachedResponse: Codable, Equatable {
        let value: String
    }

    private var opaqueJPEGPolicy: APIClient.DownloadDataPolicy {
        APIClient.DownloadDataPolicy(
            maximumBytes: 1 * 1_024 * 1_024,
            allowedMediaTypes: ["image/jpeg"]
        )
    }

    private func makeStubbedClient(
        transferTemporaryRoot: URL? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        APIClientStubURLProtocol.install(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" },
            transferTemporaryRoot: transferTemporaryRoot
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "test-family:\(UUID().uuidString)",
            accessToken: "test-access",
            refreshToken: "test-refresh"
        )
        return client
    }

    private func makeStreamingClient(transferTemporaryRoot: URL? = nil) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStreamingURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" },
            transferTemporaryRoot: transferTemporaryRoot
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "streaming-family:\(UUID().uuidString)",
            accessToken: "streaming-access",
            refreshToken: "streaming-refresh"
        )
        return client
    }

    func testUnavailableClientIdentityRejectsMutationBeforeEncodingTransportOrQueueWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnavailableClientIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OfflineHTTPMutationStore(directory: directory, maxEncodedBytes: 20_000)
        let lock = NSLock()
        var transportCount = 0
        var encodeCount = 0
        APIClientStubURLProtocol.install { request in
            lock.withLock { transportCount += 1 }
            throw URLError(.notConnectedToInternet)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { throw KeychainError.saveFailed(errSecNotAvailable) },
            offlineMutationStore: store
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "family:user",
            accessToken: "access",
            refreshToken: "refresh"
        )
        defer { client.clearSession() }

        do {
            try await client.postNoResponse(
                "/dog/activities",
                body: EncodingProbe { lock.withLock { encodeCount += 1 } }
            )
            XCTFail("A mutation without durable client identity must be rejected")
        } catch ClientIdentityError.unavailable {
            // Expected typed, actionable failure.
        }

        XCTAssertEqual(lock.withLock { encodeCount }, 0)
        XCTAssertEqual(lock.withLock { transportCount }, 0)
        let queuedCount = try await store.count(identity: "family:user")
        XCTAssertEqual(queuedCount, 0)
    }

    func testUnavailableClientIdentityStillAllowsReadOnlyRequestWithoutIdentityHeader() async throws {
        let lock = NSLock()
        var receivedClientId: String?
        APIClientStubURLProtocol.install { request in
            lock.withLock {
                receivedClientId = request.value(forHTTPHeaderField: "X-Client-Id")
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"value":"read-only"}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { throw KeychainError.loadFailed(errSecInteractionNotAllowed) }
        )
        client.baseURL = "https://api.example.test/api"

        let response: CachedResponse = try await client.get(
            "/public/read-only-\(UUID().uuidString)",
            cachePolicy: .networkOnly
        )

        XCTAssertEqual(response.value, "read-only")
        XCTAssertNil(lock.withLock { receivedClientId })
    }

    func testExplicitAuthBootstrapRouteDoesNotResolveUnavailableClientIdentity() async throws {
        let resolutionCount = LockedTestValue(0)
        let receivedHeaders = LockedTestValue<(
            clientId: String?,
            operationId: String?
        )?>(nil)
        APIClientStubURLProtocol.install { request in
            receivedHeaders.set((
                request.value(forHTTPHeaderField: "X-Client-Id"),
                request.value(forHTTPHeaderField: "X-HausKlar-Operation-ID")
            ))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"value":"authenticated"}"#.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: {
                resolutionCount.update { $0 += 1 }
                throw KeychainError.loadFailed(errSecInteractionNotAllowed)
            }
        )
        client.baseURL = "https://api.example.test/api"

        let response: CachedResponse = try await client.post(
            "/auth/login",
            body: TestPayload(firstName: "A", lastName: "B", dateOfBirth: "2000-01-01")
        )

        XCTAssertEqual(response.value, "authenticated")
        XCTAssertEqual(resolutionCount.read(), 0)
        XCTAssertNil(receivedHeaders.read()?.clientId)
        XCTAssertNil(receivedHeaders.read()?.operationId)
    }

    private func seedCachedResponse(
        _ response: CachedResponse,
        path: APIRequestPath,
        client: APIClient
    ) async throws -> String {
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: URL(string: client.baseURL + rawPath)!)
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        await FileCache.shared.set(key, data: try JSONEncoder().encode(response))
        return key
    }

    private func assertCancellation(
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected cancellation", file: file, line: line)
        } catch let error as APIError {
            XCTFail(
                "Cancellation must not be normalized as \(error)",
                file: file,
                line: line
            )
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled, file: file, line: line)
        } catch is CancellationError {
            // Native Swift task cancellation is equally valid.
        } catch {
            XCTFail("Expected cancellation, got \(error)", file: file, line: line)
        }
    }

    func testEncoderUsesSnakeCaseKeys() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let payload = TestPayload(firstName: "Alex", lastName: "Example", dateOfBirth: "1990-01-01")
        let data = try encoder.encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(json["first_name"], "Encoder should produce snake_case key 'first_name'")
        XCTAssertNotNil(json["last_name"], "Encoder should produce snake_case key 'last_name'")
        XCTAssertNotNil(json["date_of_birth"], "Encoder should produce snake_case key 'date_of_birth'")

        // Ensure camelCase keys are NOT present.
        XCTAssertNil(json["firstName"], "Encoder should not produce camelCase key 'firstName'")
        XCTAssertNil(json["lastName"], "Encoder should not produce camelCase key 'lastName'")
    }

    func testDecoderUsesSnakeCaseKeys() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let json = """
        {"first_name": "Morgan", "last_name": "Example", "date_of_birth": "1992-05-20"}
        """.data(using: .utf8)!

        let payload = try decoder.decode(TestPayload.self, from: json)
        XCTAssertEqual(payload.firstName, "Morgan")
        XCTAssertEqual(payload.lastName, "Example")
        XCTAssertEqual(payload.dateOfBirth, "1992-05-20")
    }

    func testRecentUseSummaryDecodesConsentAndFailureSignals() throws {
        let json = #"{"enabled":true,"period_days":28,"meaningful_actions":2,"failed_actions":0,"active_days":1,"use_signal":"started","repeat_modules":[],"both_adults_contributed":false,"shared_family_actions":0,"screen_views":[{"module":"today","surface":"today","views":4,"active_days":1}],"control_uses":[{"module":"facilities","action":"open_swimming_booking","surface":"today_facilities","presses":2,"active_days":1}],"workflows":[{"module":"facilities","workflow":"book_swimming","action":"book_swimming","starts":2,"completions":1,"failures":0,"abandonments":1,"queued_completions":1,"average_interactions":3.0}],"last_action_at":null}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let summary = try decoder.decode(UsageHistorySummaryDTO.self, from: Data(json.utf8))

        XCTAssertTrue(summary.enabled)
        XCTAssertEqual(summary.periodDays, 28)
        XCTAssertEqual(summary.meaningfulActions, 2)
        XCTAssertEqual(summary.failedActions, 0)
        XCTAssertEqual(summary.useSignal, "started")
        XCTAssertTrue(summary.repeatModules.isEmpty)
        XCTAssertFalse(summary.bothAdultsContributed)
        XCTAssertEqual(summary.screenViews.first?.views, 4)
        XCTAssertEqual(summary.controlUses.first?.action, "open_swimming_booking")
        XCTAssertEqual(summary.workflows.first?.completions, 1)
        XCTAssertEqual(summary.workflows.first?.queuedCompletions, 1)
    }

    func testRequestsIdentifyIOSForOptedInUsageSummary() async throws {
        let response = CachedResponse(value: "ok")
        let client = makeStubbedClient { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-HausKlar-Client"), "ios")
            let appVersion = try XCTUnwrap(
                request.value(forHTTPHeaderField: "X-HausKlar-App-Version")
            )
            XCTAssertFalse(appVersion.isEmpty)
            let httpResponse = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (httpResponse, try JSONEncoder().encode(response))
        }
        defer { client.clearSession() }

        let loaded: CachedResponse = try await client.get(
            "/tasks/source-header-\(UUID().uuidString)",
            bypassCache: true
        )

        XCTAssertEqual(loaded, response)
    }

    func testSnakeCaseRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let original = TestPayload(firstName: "Alex", lastName: "Example", dateOfBirth: "1990-01-01")
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(TestPayload.self, from: data)

        XCTAssertEqual(original, decoded, "Encode then decode should produce the original value")
    }

    func testOfflineTransportFailureUsesCachedGetResponse() async throws {
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/tasks/offline-\(UUID().uuidString)"
        let key = try await seedCachedResponse(
            CachedResponse(value: "offline copy"),
            path: path,
            client: client
        )

        let response: CachedResponse = try await client.get(path, bypassCache: true)

        XCTAssertEqual(response, CachedResponse(value: "offline copy"))
        await FileCache.shared.remove { $0 == key }
    }

    func testProvenancedGetIdentifiesOfflineFallbackWithoutChangingDefaultGet() async throws {
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/tasks/provenance-offline-\(UUID().uuidString)"
        let key = try await seedCachedResponse(
            CachedResponse(value: "offline copy"),
            path: path,
            client: client
        )

        let response: APIClient.ProvenancedGet<CachedResponse> = try await client.getWithProvenance(
            path,
            bypassCache: true
        )

        XCTAssertEqual(response.value, CachedResponse(value: "offline copy"))
        XCTAssertEqual(response.provenance, .staleFallback)
        await FileCache.shared.remove { $0 == key }
    }

    func testProvenancedGetDistinguishesNetworkFromFreshCache() async throws {
        let response = CachedResponse(value: "live")
        let requestLock = NSLock()
        var requestCount = 0
        let client = makeStubbedClient { request in
            requestLock.withLock { requestCount += 1 }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(response)
            )
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/tasks/provenance-live-\(UUID().uuidString)"

        let live: APIClient.ProvenancedGet<CachedResponse> = try await client.getWithProvenance(
            path,
            bypassCache: true
        )
        let cached: APIClient.ProvenancedGet<CachedResponse> = try await client.getWithProvenance(path)

        XCTAssertEqual(live.value, response)
        XCTAssertEqual(live.provenance, .network)
        XCTAssertEqual(cached.value, response)
        XCTAssertEqual(cached.provenance, .freshCache)
        XCTAssertEqual(requestLock.withLock { requestCount }, 1)
    }

    func testNetworkOnlyNeverReadsOrFallsBackToCachedResponse() async throws {
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/medicine/check/type/child/test-\(UUID().uuidString)"
        let key = try await seedCachedResponse(
            CachedResponse(value: "stale safety result"),
            path: path,
            client: client
        )

        do {
            let _: CachedResponse = try await client.get(path, cachePolicy: .networkOnly)
            XCTFail("Network-only safety checks must not use cached data")
        } catch APIError.networkError {
            // Expected.
        } catch {
            XCTFail("Expected a network error, got \(error)")
        }
        await FileCache.shared.remove { $0 == key }
    }

    func testNetworkOnlySuccessfulResponseIsNotCached() async throws {
        let response = CachedResponse(value: "live safety result")
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(response)
            )
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/medicine/check/type/child/test-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: URL(string: client.baseURL + rawPath)!)
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        await FileCache.shared.remove { $0 == key }

        let loaded: CachedResponse = try await client.get(path, cachePolicy: .networkOnly)

        XCTAssertEqual(loaded, response)
        let cached = await FileCache.shared.get(key)
        XCTAssertNil(cached)
    }

    func testConcurrentAuthenticatedDownloadsShareOneTransport() async throws {
        let payload = Data("one image response".utf8)
        let requestLock = NSLock()
        let firstRequestStarted = expectation(description: "first request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        var requestCount = 0
        let client = makeStubbedClient { request in
            let ordinal = requestLock.withLock {
                requestCount += 1
                return requestCount
            }
            if ordinal == 1 {
                firstRequestStarted.fulfill()
                _ = releaseFirstRequest.wait(timeout: .now() + 2)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"]
                )!,
                payload
            )
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/photos/coalesced-\(UUID().uuidString)"

        let policy = opaqueJPEGPolicy
        let first = Task { try await client.downloadData(path, policy: policy) }
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        let second = Task { try await client.downloadData(path, policy: policy) }
        try await Task.sleep(for: .milliseconds(50))
        releaseFirstRequest.signal()

        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, payload)
        XCTAssertEqual(secondValue, payload)
        XCTAssertEqual(requestLock.withLock { requestCount }, 1)
    }

    func testDownloadRejectsDeclaredOversizeBeforeReturningBytes() async throws {
        let maximumBytes = 16
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/octet-stream; charset=binary",
                        "Content-Length": String(maximumBytes + 1),
                    ]
                )!,
                Data(repeating: 0x41, count: maximumBytes)
            )
        }
        defer { client.clearSession() }
        let policy = APIClient.DownloadDataPolicy(
            maximumBytes: maximumBytes,
            allowedMediaTypes: ["application/octet-stream"]
        )

        do {
            _ = try await client.downloadData(
                "/photos/declared-oversize-\(UUID().uuidString)",
                policy: policy,
                cachePolicy: .networkOnly
            )
            XCTFail("A declared oversized response must be rejected")
        } catch APIError.decodingError {
            // Expected.
        } catch APIError.networkError {
            // Some URL loading implementations reject a short body first.
        }
    }

    func testDownloadPoliciesRejectNonpositiveLimitsAndEmptyMIMESetsBeforeTransport() async {
        let client = makeStubbedClient { _ in
            XCTFail("An invalid download policy must fail before transport")
            throw URLError(.badURL)
        }
        defer { client.clearSession() }

        do {
            _ = try await client.downloadData(
                "/photos/invalid-policy",
                policy: APIClient.DownloadDataPolicy(
                    maximumBytes: 0,
                    allowedMediaTypes: ["image/jpeg"]
                )
            )
            XCTFail("A nonpositive binary limit must be rejected")
        } catch APIError.decodingError {
            // Expected.
        } catch {
            XCTFail("Expected decodingError, got \(error)")
        }

        do {
            _ = try await client.downloadToTemporaryFile(
                "/fitness/export",
                filename: "fitness.zip",
                maximumBytes: 1_024,
                allowedMediaTypes: []
            )
            XCTFail("An empty file MIME policy must be rejected")
        } catch APIError.decodingError {
            // Expected.
        } catch {
            XCTFail("Expected decodingError, got \(error)")
        }
    }

    func testDownloadRejectsChunkedOversizeByActualFileSize() async throws {
        let maximumBytes = 16
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/octet-stream"]
                )!,
                Data(repeating: 0x42, count: maximumBytes + 1)
            )
        }
        defer { client.clearSession() }
        let policy = APIClient.DownloadDataPolicy(
            maximumBytes: maximumBytes,
            allowedMediaTypes: ["application/octet-stream"]
        )

        do {
            _ = try await client.downloadData(
                "/photos/chunked-oversize-\(UUID().uuidString)",
                policy: policy,
                cachePolicy: .networkOnly
            )
            XCTFail("An unknown-length oversized response must be rejected")
        } catch APIError.decodingError {
            // Expected.
        }
    }

    func testStreamingDataDownloadAcceptsExactUnknownLengthLimit() async throws {
        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [Data([0, 1, 2]), Data([3, 4, 5, 6, 7])]
            )
        )
        let client = makeStreamingClient()
        defer { client.clearSession() }

        let data = try await client.downloadData(
            "/photos/exact-stream-\(UUID().uuidString)",
            policy: APIClient.DownloadDataPolicy(
                maximumBytes: 8,
                allowedMediaTypes: ["application/octet-stream"]
            ),
            cachePolicy: .networkOnly
        )

        XCTAssertEqual(data, Data([0, 1, 2, 3, 4, 5, 6, 7]))
    }

    func testStreamingFileDownloadCancelsUnknownLengthAtFirstByteOverLimit() async throws {
        let stopped = expectation(description: "oversized file response cancelled")
        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [
                    Data(repeating: 0x31, count: 4),
                    Data(repeating: 0x32, count: 4),
                    Data([0x33]),
                    Data(repeating: 0x34, count: 64),
                ]
            ),
            onStop: { stopped.fulfill() }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamingDownload-\(UUID().uuidString)", isDirectory: true)
        let client = makeStreamingClient(transferTemporaryRoot: root)
        defer {
            client.clearSession()
            try? FileManager.default.removeItem(at: root)
        }

        do {
            _ = try await client.downloadToTemporaryFile(
                "/fitness/export",
                filename: "fitness.zip",
                maximumBytes: 8,
                allowedMediaTypes: ["application/octet-stream"]
            )
            XCTFail("A file response must be cancelled on its first byte over the limit")
        } catch APIError.decodingError(let error) {
            XCTAssertEqual(
                error as? BoundedHTTPPayload.ValidationError,
                .actualSizeExceedsMaximum
            )
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(APIClientStreamingURLProtocol.deliveredChunkCount, 3)
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [],
            []
        )
    }

    func testStreamingFileDownloadReturnsExactLimitInsideOwnedDirectory() async throws {
        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                chunks: [Data(repeating: 0x51, count: 4), Data(repeating: 0x52, count: 4)]
            )
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamingDownload-\(UUID().uuidString)", isDirectory: true)
        let client = makeStreamingClient(transferTemporaryRoot: root)
        defer {
            client.clearSession()
            try? FileManager.default.removeItem(at: root)
        }

        let file = try await client.downloadToTemporaryFile(
            "/fitness/export",
            filename: "fitness.zip",
            maximumBytes: 8,
            allowedMediaTypes: ["application/octet-stream"]
        )

        XCTAssertEqual(try Data(contentsOf: file).count, 8)
        XCTAssertEqual(file.lastPathComponent, "fitness.zip")
        XCTAssertEqual(file.deletingLastPathComponent().deletingLastPathComponent(), root)
        let ownedDirectory = file.deletingLastPathComponent()
        await client.releaseTemporaryDownload(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedDirectory.path))
    }

    func testStreamingErrorBodyUsesSmallIndependentCapAndCancelsOverflow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStreamingURLProtocol.self]
        let delegate = BoundedURLSessionTransportDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example.test/api/tasks"))
        )

        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(repeating: 0x45, count: 8)]
            )
        )
        let exact = try await delegate.response(
            for: request,
            in: session,
            successMaximumBytes: 1_024,
            errorMaximumBytes: 8
        )
        XCTAssertEqual(exact.response.statusCode, 500)
        XCTAssertEqual(exact.data?.count, 8)

        let stopped = expectation(description: "oversized error response cancelled")
        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(repeating: 0x45, count: 8), Data([0x46]), Data([0x47])]
            ),
            onStop: { stopped.fulfill() }
        )
        do {
            _ = try await delegate.response(
                for: request,
                in: session,
                successMaximumBytes: 1_024,
                errorMaximumBytes: 8
            )
            XCTFail("Error bodies must be cancelled at their independent cap")
        } catch let error as BoundedHTTPPayload.ValidationError {
            XCTAssertEqual(error, .actualSizeExceedsMaximum)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(APIClientStreamingURLProtocol.deliveredChunkCount, 2)
    }

    func testDownloadAcceptsExactBoundaryAndNormalizesMediaType() async throws {
        let payload = Data(repeating: 0x43, count: 16)
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": " Application/Octet-Stream ; charset=binary ",
                        "Content-Length": String(payload.count),
                    ]
                )!,
                payload
            )
        }
        defer { client.clearSession() }
        let policy = APIClient.DownloadDataPolicy(
            maximumBytes: payload.count,
            allowedMediaTypes: ["APPLICATION/OCTET-STREAM"]
        )

        let value = try await client.downloadData(
            "/photos/exact-boundary-\(UUID().uuidString)",
            policy: policy,
            cachePolicy: .networkOnly
        )

        XCTAssertEqual(value, payload)
    }

    func testDownloadRejectsUnexpectedMediaTypeWithoutStaleFallback() async throws {
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                Data("<html>not an image</html>".utf8)
            )
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/photos/mime-mismatch-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: try XCTUnwrap(URL(string: client.baseURL + rawPath)))
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        await FileCache.shared.set(key, data: Data("stale image".utf8))

        do {
            _ = try await client.downloadData(
                path,
                policy: opaqueJPEGPolicy,
                cachePolicy: .networkThenStale
            )
            XCTFail("A MIME protocol failure must not use stale bytes")
        } catch APIError.decodingError {
            // Expected.
        }
        await FileCache.shared.remove { $0 == key }
    }

    func testDownloadRejectsOversizedCachedPayload() async throws {
        let client = makeStubbedClient { _ in throw URLError(.notConnectedToInternet) }
        defer { client.clearSession() }
        let path: APIRequestPath = "/photos/cached-oversize-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: try XCTUnwrap(URL(string: client.baseURL + rawPath)))
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        await FileCache.shared.set(key, data: Data(repeating: 0x44, count: 17))
        let policy = APIClient.DownloadDataPolicy(
            maximumBytes: 16,
            allowedMediaTypes: ["application/octet-stream"]
        )

        do {
            _ = try await client.downloadData(path, policy: policy)
            XCTFail("Oversized cached bytes must never be returned")
        } catch APIError.networkError {
            // The over-policy entry was unavailable to this bounded caller.
        }
        let remaining = await FileCache.shared.get(key)
        XCTAssertEqual(remaining?.data.count, 17)
        await FileCache.shared.remove { $0 == key }
    }

    func testDownloadRejectsMalformedImageWithAllowedDeclaredType() async throws {
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/jpeg"]
                )!,
                Data("not actually a JPEG".utf8)
            )
        }
        defer { client.clearSession() }

        do {
            _ = try await client.downloadData(
                "/photos/malformed-image-\(UUID().uuidString)",
                policy: .image(maximumBytes: 1_024),
                cachePolicy: .networkOnly
            )
            XCTFail("Malformed image bytes must be rejected")
        } catch APIError.decodingError {
            // Expected.
        }
    }

    func testDownloadRejectsImageWhoseBytesDisagreeWithDeclaredMIME() async throws {
        let png = try XCTUnwrap(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )
        )
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "image/jpeg"]
                )!,
                png
            )
        }
        defer { client.clearSession() }

        do {
            _ = try await client.downloadData(
                "/photos/content-type-confusion-\(UUID().uuidString)",
                policy: .image(maximumBytes: 1_024),
                cachePolicy: .networkOnly
            )
            XCTFail("Image bytes must agree with their declared media type")
        } catch APIError.decodingError {
            // Expected.
        }
    }

    func testFileBackedUploadResponseRejectsDeclaredOversizeBeforeBodyDelivery() async throws {
        let stopped = expectation(description: "declared oversized upload response cancelled")
        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Content-Length": "9",
                ],
                chunks: [Data(repeating: 0x41, count: 8)]
            ),
            onStop: { stopped.fulfill() }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStreamingURLProtocol.self]
        let delegate = BoundedURLSessionTransportDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedUpload-\(UUID().uuidString)")
        try Data("request".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example.test/api/artworks"))
        )
        request.httpMethod = "POST"

        do {
            _ = try await delegate.uploadResponse(
                for: request,
                fromFile: source,
                in: session,
                successMaximumBytes: 8,
                errorMaximumBytes: 4
            )
            XCTFail("A declared oversized upload response must be rejected")
        } catch let error as BoundedHTTPPayload.ValidationError {
            XCTAssertEqual(error, .declaredSizeExceedsMaximum)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(APIClientStreamingURLProtocol.deliveredChunkCount, 0)
    }

    func testFileBackedUploadResponseAcceptsExactUnknownLengthAndCancelsNextByte() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStreamingURLProtocol.self]
        let delegate = BoundedURLSessionTransportDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedUpload-\(UUID().uuidString)")
        try Data("request".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example.test/api/artworks"))
        )
        request.httpMethod = "POST"

        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [Data(repeating: 0x41, count: 3), Data(repeating: 0x42, count: 5)]
            )
        )
        let exact = try await delegate.uploadResponse(
            for: request,
            fromFile: source,
            in: session,
            successMaximumBytes: 8,
            errorMaximumBytes: 4
        )
        XCTAssertEqual(exact.data, Data(repeating: 0x41, count: 3) + Data(repeating: 0x42, count: 5))

        let stopped = expectation(description: "unknown-length upload response cancelled")
        APIClientStreamingURLProtocol.install(
            script: .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                chunks: [
                    Data(repeating: 0x41, count: 4),
                    Data(repeating: 0x42, count: 4),
                    Data([0x43]),
                    Data(repeating: 0x44, count: 32),
                ]
            ),
            onStop: { stopped.fulfill() }
        )
        do {
            _ = try await delegate.uploadResponse(
                for: request,
                fromFile: source,
                in: session,
                successMaximumBytes: 8,
                errorMaximumBytes: 4
            )
            XCTFail("The first byte over the upload response limit must cancel transport")
        } catch let error as BoundedHTTPPayload.ValidationError {
            XCTAssertEqual(error, .actualSizeExceedsMaximum)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(APIClientStreamingURLProtocol.deliveredChunkCount, 3)
    }

    func testGenericJSONResponseEnforcesDeclaredBoundaryWithoutCacheFallback() async throws {
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Content-Length": String(APIClient.maximumJSONResponseBytes + 1),
                    ]
                )!,
                Data(#"{"value":"small body"}"#.utf8)
            )
        }
        defer { client.clearSession() }

        do {
            let _: CachedResponse = try await client.get(
                "/tasks/declared-response-boundary-\(UUID().uuidString)",
                cachePolicy: .networkThenStale
            )
            XCTFail("An oversized declared JSON response must be rejected")
        } catch APIError.decodingError {
            // Expected.
        } catch APIError.networkError {
            // Some URL loading implementations reject a short body first.
        }
    }

    func testDifferentDownloadPoliciesNeverShareLooserInflightTransport() async throws {
        let payload = Data(repeating: 0x45, count: 32)
        let requestLock = NSLock()
        var requestCount = 0
        let client = makeStubbedClient { request in
            requestLock.withLock { requestCount += 1 }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/octet-stream"]
                )!,
                payload
            )
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/photos/policy-coalescing-\(UUID().uuidString)"
        let loose = APIClient.DownloadDataPolicy(
            maximumBytes: payload.count,
            allowedMediaTypes: ["application/octet-stream"]
        )
        let strict = APIClient.DownloadDataPolicy(
            maximumBytes: payload.count - 1,
            allowedMediaTypes: ["application/octet-stream"]
        )

        async let looseValue = client.downloadData(path, policy: loose, cachePolicy: .networkOnly)
        async let strictValue = client.downloadData(path, policy: strict, cachePolicy: .networkOnly)
        let resolvedLooseValue = try await looseValue
        XCTAssertEqual(resolvedLooseValue, payload)
        do {
            _ = try await strictValue
            XCTFail("A strict waiter must not inherit a loose response policy")
        } catch APIError.decodingError {
            // Expected.
        }
        XCTAssertEqual(requestLock.withLock { requestCount }, 2)
    }

    func testFreshDownloadCacheRejectsAccountReplacementDuringActorHop() async throws {
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            client.cacheReadBarrierForTesting = nil
            client.clearSession()
        }
        let path: APIRequestPath = "/documents/account-switch-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: URL(string: client.baseURL + rawPath)!)
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        let privateData = Data("account A private image".utf8)
        await FileCache.shared.set(key, data: privateData)

        let cacheRead = expectation(description: "fresh cache read suspended")
        let releaseRead = TestAsyncGate()
        client.cacheReadBarrierForTesting = {
            cacheRead.fulfill()
            await releaseRead.wait()
        }
        let policy = opaqueJPEGPolicy
        let download = Task { try await client.downloadData(path, policy: policy) }
        await fulfillment(of: [cacheRead], timeout: 2)
        _ = client.installSession(
            identity: "replacement-family:b",
            accessToken: "access-b",
            refreshToken: "refresh-b"
        )
        await releaseRead.open()

        do {
            _ = try await download.value
            XCTFail("An A cache hit must not cross an A-to-B session boundary")
        } catch APIError.unauthorized {
            // Expected.
        } catch {
            XCTFail("Expected unauthorized, got \(error)")
        }
        await FileCache.shared.remove { $0 == key }
    }

    func testFreshDownloadCacheLeaseSurvivesTokenRotation() async throws {
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer {
            client.cacheReadBarrierForTesting = nil
            client.clearSession()
        }
        let original = try XCTUnwrap(client.currentSessionSnapshot())
        let path: APIRequestPath = "/documents/token-rotation-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: URL(string: client.baseURL + rawPath)!)
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        let image = Data("same-login image".utf8)
        await FileCache.shared.set(key, data: image)

        let cacheRead = expectation(description: "fresh cache read suspended")
        let releaseRead = TestAsyncGate()
        client.cacheReadBarrierForTesting = {
            cacheRead.fulfill()
            await releaseRead.wait()
        }
        let policy = opaqueJPEGPolicy
        let download = Task { try await client.downloadData(path, policy: policy) }
        await fulfillment(of: [cacheRead], timeout: 2)
        XCTAssertTrue(
            client.installRefreshedTokens(
                accessToken: "rotated-access",
                refreshToken: "rotated-refresh",
                expectedSession: original
            )
        )
        await releaseRead.open()

        let downloaded = try await download.value
        XCTAssertEqual(downloaded, image)
        await FileCache.shared.remove { $0 == key }
    }

    func testCancellingOneSharedDownloadDoesNotCancelAnotherWaiter() async throws {
        let payload = Data("shared image response".utf8)
        let requestLock = NSLock()
        let firstRequestStarted = expectation(description: "first request started")
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        var requestCount = 0
        let client = makeStubbedClient { request in
            let ordinal = requestLock.withLock {
                requestCount += 1
                return requestCount
            }
            if ordinal == 1 {
                firstRequestStarted.fulfill()
                _ = releaseFirstRequest.wait(timeout: .now() + 2)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"]
                )!,
                payload
            )
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/photos/shared-cancellation-\(UUID().uuidString)"

        let policy = opaqueJPEGPolicy
        let cancelled = Task { try await client.downloadData(path, policy: policy) }
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        let survivor = Task { try await client.downloadData(path, policy: policy) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        releaseFirstRequest.signal()

        await assertCancellation { _ = try await cancelled.value }
        let survivorValue = try await survivor.value
        XCTAssertEqual(survivorValue, payload)
        XCTAssertEqual(requestLock.withLock { requestCount }, 1)
    }

    func testFinanceNeverReadsGeneralOfflineCache() async throws {
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/finance/accounts"
        let key = try await seedCachedResponse(
            CachedResponse(value: "financial data must not be cached"),
            path: path,
            client: client
        )

        do {
            let _: CachedResponse = try await client.get(path)
            XCTFail("Finance must not use the app's general offline cache")
        } catch APIError.networkError {
            // Expected: Finance remains online-only.
        } catch {
            XCTFail("Expected a network error, got \(error)")
        }
        await FileCache.shared.remove { $0 == key }
    }

    func testFinanceSuccessfulGetIsNotWrittenToGeneralOfflineCache() async throws {
        let response = CachedResponse(value: "live financial data")
        let client = makeStubbedClient { request in
            let httpResponse = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Cache-Control": "no-store",
                    "Content-Type": "application/json",
                ]
            )!
            return (httpResponse, try JSONEncoder().encode(response))
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/finance/accounts/test-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: URL(string: client.baseURL + rawPath)!)
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        await FileCache.shared.remove { $0 == key }

        let loaded: CachedResponse = try await client.get(path)

        XCTAssertEqual(loaded, response)
        let cached = await FileCache.shared.get(key)
        XCTAssertNil(cached)
    }

    func testFitnessSuccessfulGetUsesTypedStoreInsteadOfGeneralOfflineCache() async throws {
        let response = CachedResponse(value: "fitness data belongs in GRDB")
        let client = makeStubbedClient { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(response)
            )
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/fitness/activities/test-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: URL(string: client.baseURL + rawPath)!)
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        await FileCache.shared.remove { $0 == key }

        let loaded: CachedResponse = try await client.get(path)

        XCTAssertEqual(loaded, response)
        let cached = await FileCache.shared.get(key)
        XCTAssertNil(cached)
    }

    func testCaregiverHandoverIsNotWrittenToGeneralOfflineCache() async throws {
        let response = CachedResponse(value: "contains caregiver-only detail")
        let client = makeStubbedClient { request in
            let httpResponse = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Cache-Control": "no-store",
                    "Content-Type": "application/json",
                ]
            )!
            return (httpResponse, try JSONEncoder().encode(response))
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/babysitter/handover/test-\(UUID().uuidString)"
        let rawPath = try path.validatedValue()
        var request = URLRequest(url: URL(string: client.baseURL + rawPath)!)
        request.setValue("Bearer test-access", forHTTPHeaderField: "Authorization")
        let key = try client.responseCacheKey(for: request)
        await FileCache.shared.remove { $0 == key }

        let loaded: CachedResponse = try await client.get(path)

        XCTAssertEqual(loaded, response)
        let cached = await FileCache.shared.get(key)
        XCTAssertNil(cached)
    }

    func testForbiddenGetNeverFallsBackToCachedResponse() async throws {
        let client = makeStubbedClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"detail":"Forbidden"}"#.utf8))
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/tasks/forbidden-\(UUID().uuidString)"
        let key = try await seedCachedResponse(
            CachedResponse(value: "must not be shown"),
            path: path,
            client: client
        )

        do {
            let _: CachedResponse = try await client.get(path, bypassCache: true)
            XCTFail("A permission failure must not be hidden by stale data")
        } catch APIError.forbidden {
            // Expected.
        } catch {
            XCTFail("Expected forbidden, got \(error)")
        }
        await FileCache.shared.remove { $0 == key }
    }

    func testMalformedSuccessfulGetNeverFallsBackToCachedResponse() async throws {
        let client = makeStubbedClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"unexpected":true}"#.utf8))
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/tasks/malformed-\(UUID().uuidString)"
        let key = try await seedCachedResponse(
            CachedResponse(value: "must not be shown"),
            path: path,
            client: client
        )

        do {
            let _: CachedResponse = try await client.get(path, bypassCache: true)
            XCTFail("A decoding failure must not be hidden by stale data")
        } catch APIError.decodingError {
            // Expected.
        } catch {
            XCTFail("Expected decodingError, got \(error)")
        }
        await FileCache.shared.remove { $0 == key }
    }

    func testCancelledGetNeverFallsBackToCachedResponse() async throws {
        let client = makeStubbedClient { _ in
            throw URLError(.cancelled)
        }
        defer { client.clearSession() }
        let path: APIRequestPath = "/tasks/cancelled-\(UUID().uuidString)"
        let key = try await seedCachedResponse(
            CachedResponse(value: "must not be shown"),
            path: path,
            client: client
        )

        do {
            let _: CachedResponse = try await client.get(path, bypassCache: true)
            XCTFail("Cancellation must not be hidden by stale data")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch is CancellationError {
            // URLSession is also allowed to surface native task cancellation.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        await FileCache.shared.remove { $0 == key }
    }

    func testCancellationStaysCancellationAcrossMutationTransports() async {
        let client = makeStubbedClient { _ in
            throw URLError(.cancelled)
        }
        defer { client.clearSession() }

        await assertCancellation {
            let _: CachedResponse = try await client.post(
                "/tasks/cancelled-post",
                body: CachedResponse(value: "new task")
            )
        }
        await assertCancellation {
            try await client.postNoResponse(
                "/tasks/cancelled-no-response",
                body: CachedResponse(value: "new task")
            )
        }
        await assertCancellation {
            _ = try await client.postData(
                "/tasks/cancelled-data",
                body: CachedResponse(value: "new task")
            )
        }
        await assertCancellation {
            let _: CachedResponse = try await client.uploadMultipartFiles(
                "/documents/",
                fileFieldName: "files",
                files: [("document.txt", "text/plain", Data("test".utf8))],
                orderedFields: []
            )
        }
        await assertCancellation {
            try await client.delete("/tasks/cancelled-delete")
        }
    }

    func testCaregiverAccessMutationsAreNeverQueuedOffline() async {
        let client = makeStubbedClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }

        do {
            let _: CachedResponse = try await client.post(
                "/babysitter/bookings/booking-1/revoke"
            )
            XCTFail("Caregiver access changes must require a live server response")
        } catch APIError.networkError {
            // Expected: a delayed revoke would leave a sitter with access.
        } catch {
            XCTFail("Expected a network error, got \(error)")
        }
        let pending = await client.pendingOfflineMutationCount()
        XCTAssertEqual(pending, 0)
    }

    func testPasswordChangeResponseDecodesRotatedCredentials() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = """
        {
          "access_token": "new-access",
          "refresh_token": "new-refresh",
          "token_type": "bearer",
          "user": {
            "id": "dom",
            "name": "Alex",
            "email": "dom@example.invalid",
            "role": "admin",
            "priority": 5,
            "family_id": "family",
            "must_change_password": false
          }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(AuthService.LoginResponse.self, from: data)

        XCTAssertEqual(response.accessToken, "new-access")
        XCTAssertEqual(response.refreshToken, "new-refresh")
        XCTAssertEqual(response.user.mustChangePassword, false)
    }

    @MainActor
    func testPasswordChangedInstallsRotatedCredentials() async throws {
        let client = APIClient.shared
        let previousSession = client.currentSessionSnapshot()
        defer { restoreSharedClientSession(previousSession) }
        let user = UserProfile(
            id: "dom",
            name: "Alex",
            email: "dom@example.invalid",
            role: "admin",
            priority: 5,
            familyId: "family",
            mustChangePassword: false
        )
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        defaults.set("family:dom", forKey: AppState.localOwnerKey)
        configureInMemoryAppStateSession(state)
        state.configureLocalIdentityBoundary(modelContext: context, defaults: defaults)

        try await state.passwordChanged(
            accessToken: "rotated-access",
            refreshToken: "rotated-refresh",
            user: user
        )

        XCTAssertEqual(client.accessToken, "rotated-access")
        XCTAssertEqual(client.refreshToken, "rotated-refresh")
        XCTAssertEqual(state.currentUser, user)
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertFalse(state.mustChangePassword)
        await state.logout()
    }

    @MainActor
    func testSharedAddHubCanBeOpenedFromAnyFeature() {
        let state = AppState()

        XCTAssertFalse(state.showingAddHub)
        state.openAddHub()

        XCTAssertTrue(state.showingAddHub)
    }

    func testCacheKeySurvivesAccessTokenRotationWithinOneIdentity() throws {
        let client = APIClient.shared
        let previousIdentity = client.cacheIdentity
        defer { client.cacheIdentity = previousIdentity }
        client.cacheIdentity = "family:user"
        var request = URLRequest(url: URL(string: "https://example.test/api/tasks")!)
        request.setValue("Bearer first", forHTTPHeaderField: "Authorization")
        let first = try client.responseCacheKey(for: request)

        request.setValue("Bearer rotated", forHTTPHeaderField: "Authorization")
        let rotated = try client.responseCacheKey(for: request)
        client.cacheIdentity = "family:another-user"
        let anotherUser = try client.responseCacheKey(for: request)

        XCTAssertEqual(first, rotated)
        XCTAssertNotEqual(rotated, anotherUser)
    }

    func testStaleRefreshResponseCannotOverwriteNewSession() {
        let client = APIClient.shared
        let previous = client.currentSessionSnapshot()
        defer {
            if let previous {
                client.installSession(
                    identity: previous.identity,
                    accessToken: previous.accessToken,
                    refreshToken: previous.refreshToken
                )
            } else {
                client.clearSession()
            }
        }
        let accountA = client.installSession(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )

        client.clearSession()
        let accountB = client.installSession(
            identity: "family-b:b",
            accessToken: "access-b",
            refreshToken: "refresh-b"
        )
        let staleInstall = client.installRefreshedTokens(
            accessToken: "rotated-a",
            refreshToken: "rotated-refresh-a",
            expectedSession: accountA
        )

        XCTAssertFalse(staleInstall)
        XCTAssertEqual(client.currentSessionSnapshot(), accountB)
    }

    func testInstallSessionReturnsTheExactAtomicSnapshotWithoutOptionalReconstruction() {
        let client = APIClient(sessionConfiguration: .ephemeral)
        defer { client.clearSession() }
        let first = client.installSession(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )
        let second = client.installSession(
            identity: "family-b:b",
            accessToken: "access-b",
            refreshToken: "refresh-b"
        )

        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertEqual(second.identity, "family-b:b")
        XCTAssertEqual(second.accessToken, "access-b")
        XCTAssertEqual(second.refreshToken, "refresh-b")
        XCTAssertEqual(client.currentSessionSnapshot(), second)
    }

    func testTokenRotationPersistenceFailureLeavesMemoryAndEnvelopeUnchanged() {
        enum InjectedFailure: Error { case keychainWrite }
        let userJSON = #"{"id":"a","name":"A","email":"demo-person-44@example.invalid","role":"user","priority":1,"familyId":"family-a"}"#
        let originalEnvelope = StoredSessionEnvelope(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a",
            userJSON: userJSON
        )
        let storedEnvelope = originalEnvelope
        let client = APIClient(
            sessionConfiguration: .ephemeral,
            loadSessionEnvelope: { storedEnvelope },
            saveSessionEnvelope: { _ in throw InjectedFailure.keychainWrite }
        )
        let original = client.installSession(
            identity: originalEnvelope.identity,
            accessToken: originalEnvelope.accessToken,
            refreshToken: originalEnvelope.refreshToken,
            persistTokenRotation: true
        )

        let installed = client.installRefreshedTokens(
            accessToken: "unpersisted-access",
            refreshToken: "unpersisted-refresh",
            expectedSession: original
        )

        XCTAssertFalse(installed)
        XCTAssertEqual(client.currentSessionSnapshot(), original)
        XCTAssertEqual(storedEnvelope, originalEnvelope)
    }

    func testTokenRotationUpdatesOneAuthoritativeEnvelopeBeforeMemory() {
        let userJSON = #"{"id":"a","name":"A","email":"demo-person-44@example.invalid","role":"user","priority":1,"familyId":"family-a"}"#
        let originalEnvelope = StoredSessionEnvelope(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a",
            userJSON: userJSON
        )
        let storedEnvelope = LockedTestValue(originalEnvelope)
        let client = APIClient(
            sessionConfiguration: .ephemeral,
            loadSessionEnvelope: { storedEnvelope.read() },
            saveSessionEnvelope: { storedEnvelope.set($0) }
        )
        let original = client.installSession(
            identity: originalEnvelope.identity,
            accessToken: originalEnvelope.accessToken,
            refreshToken: originalEnvelope.refreshToken,
            persistTokenRotation: true
        )

        XCTAssertTrue(
            client.installRefreshedTokens(
                accessToken: "rotated-access",
                refreshToken: "rotated-refresh",
                expectedSession: original
            )
        )

        XCTAssertEqual(storedEnvelope.read().accessToken, "rotated-access")
        XCTAssertEqual(storedEnvelope.read().refreshToken, "rotated-refresh")
        XCTAssertEqual(client.currentSessionSnapshot()?.accessToken, "rotated-access")
        XCTAssertEqual(client.currentSessionSnapshot()?.refreshToken, "rotated-refresh")
    }

    func testProfileWriteCannotOverwriteTokensRotatedWhileItWaits() async throws {
        let original = StoredSessionEnvelope(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a",
            userJSON: #"{"name":"Old"}"#
        )
        let persistenceState = LockedTestValue((
            envelope: original,
            shouldPauseProfileLoad: false
        ))
        let profileLoadStarted = expectation(description: "profile load holds session lock")
        let allowProfileLoad = DispatchSemaphore(value: 0)
        let client = APIClient(
            sessionConfiguration: .ephemeral,
            loadSessionEnvelope: {
                let pause = persistenceState.read().shouldPauseProfileLoad
                if pause {
                    profileLoadStarted.fulfill()
                    _ = allowProfileLoad.wait(timeout: .now() + 2)
                }
                return persistenceState.read().envelope
            },
            saveSessionEnvelope: { envelope in
                persistenceState.update { $0.envelope = envelope }
            }
        )
        let session = client.installSession(
            identity: original.identity,
            accessToken: original.accessToken,
            refreshToken: original.refreshToken,
            persistTokenRotation: true
        )
        persistenceState.update { $0.shouldPauseProfileLoad = true }

        let profile = Task.detached {
            try client.updateStoredProfile(
                identity: original.identity,
                userJSON: #"{"name":"New"}"#
            )
        }
        await fulfillment(of: [profileLoadStarted], timeout: 2)
        let rotation = Task.detached {
            client.installRefreshedTokens(
                accessToken: "rotated-access",
                refreshToken: "rotated-refresh",
                expectedSession: session
            )
        }
        persistenceState.update { $0.shouldPauseProfileLoad = false }
        allowProfileLoad.signal()

        try await profile.value
        let rotated = await rotation.value
        XCTAssertTrue(rotated)
        let final = persistenceState.read().envelope
        XCTAssertEqual(final.userJSON, #"{"name":"New"}"#)
        XCTAssertEqual(final.accessToken, "rotated-access")
        XCTAssertEqual(final.refreshToken, "rotated-refresh")
    }

    func testCanceledRefreshCannotLockSameUserRelogin() async {
        let client = APIClient.shared
        let previous = client.currentSessionSnapshot()
        let previousCallback = client.onAuthFailure
        defer {
            client.onAuthFailure = previousCallback
            if let previous {
                client.installSession(
                    identity: previous.identity,
                    accessToken: previous.accessToken,
                    refreshToken: previous.refreshToken
                )
            } else {
                client.clearSession()
            }
        }
        let oldSession = client.installSession(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )
        client.clearSession()
        _ = client.installSession(
            identity: "family-a:a",
            accessToken: "access-a2",
            refreshToken: "refresh-a2"
        )
        let callbackCount = LockedTestValue(0)
        client.onAuthFailure = { _ in callbackCount.update { $0 += 1 } }

        await client.deliverAuthFailureIfCurrent(oldSession)

        XCTAssertEqual(callbackCount.read(), 0)
    }

    func testOldAccountRequestCannotRefreshOrRetryAfterNewAccountLogin() {
        let client = APIClient.shared
        let previous = client.currentSessionSnapshot()
        defer {
            if let previous {
                client.installSession(
                    identity: previous.identity,
                    accessToken: previous.accessToken,
                    refreshToken: previous.refreshToken
                )
            } else {
                client.clearSession()
            }
        }
        let accountA = client.installSession(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )
        var oldRequest = URLRequest(url: URL(string: "https://example.test/api/tasks")!)
        oldRequest.setValue("Bearer access-a", forHTTPHeaderField: "Authorization")
        oldRequest.setValue(
            String(accountA.generation),
            forHTTPHeaderField: APIClient.sessionGenerationHeader
        )
        _ = client.installSession(
            identity: "family-b:b",
            accessToken: "access-b",
            refreshToken: "refresh-b"
        )

        XCTAssertNil(client.sessionSnapshot(for: oldRequest))
        XCTAssertEqual(client.currentSessionSnapshot()?.identity, "family-b:b")
    }

    func testDelayedAccountASuccessCannotRepopulateCacheAfterAccountBLogin() async throws {
        let client = APIClient.shared
        let previous = client.currentSessionSnapshot()
        defer {
            if let previous {
                client.installSession(
                    identity: previous.identity,
                    accessToken: previous.accessToken,
                    refreshToken: previous.refreshToken
                )
            } else {
                client.clearSession()
            }
        }

        let accountA = client.installSession(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )
        var request = URLRequest(
            url: URL(string: "https://example.test/api/tasks/delayed-\(UUID().uuidString)")!
        )
        request.setValue("Bearer access-a", forHTTPHeaderField: "Authorization")
        request.setValue(
            String(accountA.generation),
            forHTTPHeaderField: APIClient.sessionGenerationHeader
        )
        let cacheKey = try client.responseCacheKey(for: request)
        await FileCache.shared.remove { $0 == cacheKey }

        var releaseResponse: CheckedContinuation<Void, Never>?
        let requestStarted = expectation(description: "account A request started")
        let delayedResponse = Task {
            await withCheckedContinuation { continuation in
                releaseResponse = continuation
                requestStarted.fulfill()
            }
            try await client.cacheSuccessfulGetResponse(
                Data(#"{"id":"private-a"}"#.utf8),
                cacheKey: cacheKey,
                request: request
            )
        }
        await fulfillment(of: [requestStarted])

        _ = client.installSession(
            identity: "family-b:b",
            accessToken: "access-b",
            refreshToken: "refresh-b"
        )
        // This mirrors the identity-boundary cache purge that completes before B
        // becomes visible. The delayed A success must not write behind it.
        await FileCache.shared.remove { $0 == cacheKey }
        releaseResponse?.resume()

        do {
            try await delayedResponse.value
            XCTFail("An old account's successful response must be rejected")
        } catch APIError.unauthorized {
            // Expected.
        } catch {
            XCTFail("Expected unauthorized, got \(error)")
        }
        let repopulated = await FileCache.shared.get(cacheKey)
        XCTAssertNil(repopulated)
    }

    func testSuccessfulResponseGenerationSurvivesTokenRotation() async throws {
        let client = APIClient.shared
        let previous = client.currentSessionSnapshot()
        defer {
            if let previous {
                client.installSession(
                    identity: previous.identity,
                    accessToken: previous.accessToken,
                    refreshToken: previous.refreshToken
                )
            } else {
                client.clearSession()
            }
        }

        let account = client.installSession(
            identity: "family-a:a",
            accessToken: "access-a",
            refreshToken: "refresh-a"
        )
        var request = URLRequest(
            url: URL(string: "https://example.test/api/tasks/rotated-\(UUID().uuidString)")!
        )
        request.setValue("Bearer access-a", forHTTPHeaderField: "Authorization")
        request.setValue(
            String(account.generation),
            forHTTPHeaderField: APIClient.sessionGenerationHeader
        )
        let cacheKey = try client.responseCacheKey(for: request)
        XCTAssertTrue(
            client.installRefreshedTokens(
                accessToken: "access-a-rotated",
                refreshToken: "refresh-a-rotated",
                expectedSession: account
            )
        )

        try await client.cacheSuccessfulGetResponse(
            Data(#"{"id":"same-login"}"#.utf8),
            cacheKey: cacheKey,
            request: request
        )

        let cached = await FileCache.shared.get(cacheKey)
        XCTAssertEqual(cached?.data, Data(#"{"id":"same-login"}"#.utf8))
        await FileCache.shared.remove { $0 == cacheKey }
    }

    @MainActor
    func testLogoutAttemptsRevocationAndAlwaysClearsLocalSession() async throws {
        let previousSession = APIClient.shared.currentSessionSnapshot()
        defer { restoreSharedClientSession(previousSession) }
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        defaults.set("family:user", forKey: AppState.localOwnerKey)
        configureInMemoryAppStateSession(state)
        configureInMemoryLocalIdentityBoundary(
            state,
            modelContext: context,
            defaults: defaults
        )
        let user = UserProfile(
            id: "user",
            name: "User",
            email: "demo-person-36@example.invalid",
            role: "user",
            priority: 1,
            familyId: "family",
            mustChangePassword: false
        )
        try await state.login(accessToken: "access", refreshToken: "refresh", user: user)
        let fitnessStoreDirectory = try XCTUnwrap(
            FitnessDatabase.shared.activeStoreURL?.deletingLastPathComponent()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fitnessStoreDirectory.path))
        state.openAddHub()
        state.showingAssistantChat = true
        var attemptedRevocation = false

        await state.logoutAndRevoke {
            attemptedRevocation = true
            throw URLError(.notConnectedToInternet)
        }

        XCTAssertTrue(attemptedRevocation)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(state.showingAddHub)
        XCTAssertFalse(state.showingAssistantChat)
        XCTAssertNil(APIClient.shared.accessToken)
        XCTAssertNil(APIClient.shared.refreshToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fitnessStoreDirectory.path))
    }

    @MainActor
    func testAuthLockPreservesOwnerWorkAndDifferentIdentityPurgesBeforeActivation() async throws {
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        let previousSession = APIClient.shared.currentSessionSnapshot()
        defer { restoreSharedClientSession(previousSession) }

        let userA = UserProfile(
            id: "a", name: "Account A", email: "demo-person-44@example.invalid", role: "user",
            priority: 1, familyId: "family-a", mustChangePassword: false
        )
        let userB = UserProfile(
            id: "b", name: "Account B", email: "demo-person-46@example.invalid", role: "user",
            priority: 1, familyId: "family-b", mustChangePassword: false
        )
        defaults.set("family-a:a", forKey: AppState.localOwnerKey)
        context.insert(FamilyTask(id: "account-a-task", title: "Private A task"))
        context.insert(OfflineAction(tableName: "tasks", recordId: "account-a-task"))
        try context.save()

        configureInMemoryAppStateSession(state)
        configureInMemoryLocalIdentityBoundary(
            state,
            modelContext: context,
            defaults: defaults
        )
        XCTAssertEqual(defaults.string(forKey: AppState.localOwnerKey), "family-a:a")
        try await state.login(accessToken: "access-a", refreshToken: "refresh-a", user: userA)
        let fitnessStoreDirectory = try XCTUnwrap(
            FitnessDatabase.shared.activeStoreURL?.deletingLastPathComponent()
        )

        let asset = try DocumentCaptureService.makeTextDocument("Account A private document")
        let uploadLease = try XCTUnwrap(DocumentUploadService.shared.currentIdentityLease)
        let pending = try DocumentUploadService.shared.enqueue(
            asset: asset,
            title: "A document",
            category: .other,
            documentDate: nil,
            extractedText: "",
            notes: "",
            personIds: [],
            suggestions: [],
            useHermes: false,
            modelContext: context,
            expectedIdentityLease: uploadLease
        )
        DocumentCaptureService.removeTemporaryAsset(asset)
        let pendingPath = pending.filePath
        SyncManager.shared.lastSyncTimestamp = "2026-07-17T12:00:00Z"
        UserDefaults.standard.set("2026-07-17T12:00:00Z", forKey: "sync.lastSyncTimestamp")

        await state.lockForReauthentication()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FamilyTask>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OfflineAction>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PendingDocumentUpload>()), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fitnessStoreDirectory.path))
        XCTAssertFalse(SyncManager.shared.isIdentityActive)

        try await state.login(accessToken: "access-a2", refreshToken: "refresh-a2", user: userA)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OfflineAction>()), 1)
        XCTAssertTrue(DocumentUploadService.shared.multipartFields(for: pending)["document_id"] == pending.id)

        await state.lockForReauthentication()
        try await state.login(accessToken: "access-b", refreshToken: "refresh-b", user: userB)

        XCTAssertTrue(try context.fetch(FetchDescriptor<FamilyTask>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<OfflineAction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<PendingDocumentUpload>()).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingPath))
        XCTAssertNil(SyncManager.shared.lastSyncTimestamp)
        XCTAssertNil(UserDefaults.standard.string(forKey: "sync.lastSyncTimestamp"))
        XCTAssertEqual(defaults.string(forKey: AppState.localOwnerKey), "family-b:b")
        XCTAssertTrue(SyncManager.shared.isIdentityActive)
        await state.logout()
    }

    @MainActor
    func testLegacyOwnerAdoptionPreservesKnownSignedInAccountsOnly() {
        let suiteName = "HausKlarTests.LegacyOwner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let user = UserProfile(
            id: "a", name: "Account A", email: "demo-person-44@example.invalid", role: "user",
            priority: 1, familyId: "family-a", mustChangePassword: false
        )

        XCTAssertTrue(AppState.adoptLegacyOwnerIfNeeded(user: user, defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: AppState.localOwnerKey), "family-a:a")
        XCTAssertFalse(AppState.adoptLegacyOwnerIfNeeded(user: user, defaults: defaults))

        defaults.removeObject(forKey: AppState.localOwnerKey)
        defaults.set(true, forKey: AppState.localResetRequiredKey)
        XCTAssertFalse(AppState.adoptLegacyOwnerIfNeeded(user: user, defaults: defaults))
        XCTAssertNil(defaults.string(forKey: AppState.localOwnerKey))
    }

    @MainActor
    func testPurgeFailureBlocksDifferentIdentityActivation() async throws {
        enum TestFailure: Error { case purgeFailed }
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        let previousSession = APIClient.shared.currentSessionSnapshot()
        defer { restoreSharedClientSession(previousSession) }
        defaults.set("family-a:a", forKey: AppState.localOwnerKey)
        context.insert(OfflineAction(tableName: "tasks", recordId: "private-a"))
        try context.save()
        configureInMemoryAppStateSession(state)
        state.configureLocalIdentityBoundary(
            modelContext: context,
            defaults: defaults,
            purge: { _, _ in throw TestFailure.purgeFailed }
        )
        let userB = UserProfile(
            id: "b", name: "Account B", email: "demo-person-46@example.invalid", role: "user",
            priority: 1, familyId: "family-b", mustChangePassword: false
        )

        do {
            try await state.login(accessToken: "access-b", refreshToken: "refresh-b", user: userB)
            XCTFail("A different identity must not activate after a failed purge")
        } catch TestFailure.purgeFailed {
            // Expected.
        }

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertFalse(SyncManager.shared.isIdentityActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OfflineAction>()), 1)
        XCTAssertEqual(defaults.string(forKey: AppState.localOwnerKey), "family-a:a")
        XCTAssertTrue(defaults.bool(forKey: AppState.localResetRequiredKey))
    }

    @MainActor
    func testIdentityTransitionsDoNotInterleave() async throws {
        let previousSession = APIClient.shared.currentSessionSnapshot()
        defer { restoreSharedClientSession(previousSession) }
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        defaults.set("family-a:a", forKey: AppState.localOwnerKey)
        let purgeEntered = expectation(description: "login entered identity purge")
        let releasePurge = TestAsyncGate()
        let purgeCallCount = LockedTestValue(0)
        configureInMemoryAppStateSession(state)
        state.configureLocalIdentityBoundary(
            modelContext: context,
            defaults: defaults,
            purge: { _, _ in
                let call = purgeCallCount.update { count in
                    count += 1
                    return count
                }
                if call == 1 {
                    purgeEntered.fulfill()
                }
                await releasePurge.wait()
            }
        )
        let userB = UserProfile(
            id: "b", name: "Account B", email: "demo-person-46@example.invalid", role: "user",
            priority: 1, familyId: "family-b", mustChangePassword: false
        )
        let login = Task {
            try await state.login(
                accessToken: "access-b",
                refreshToken: "refresh-b",
                user: userB
            )
        }
        await fulfillment(of: [purgeEntered], timeout: 2)

        await state.lockForReauthentication()
        await releasePurge.open()
        try await login.value

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.currentUser, userB)
        XCTAssertFalse(state.identityTransitionInProgress)
        await state.logout()
    }

    @MainActor
    func testUnavailableClientIdentityBlocksAuthenticationAndSyncActivationWithoutQueueWrite() async throws {
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        await SyncManager.shared.suspendAndReset()
        context.insert(OfflineAction(tableName: "tasks", recordId: "retained-action"))
        try context.save()
        var sessionSaveAttempted = false
        state.configureSessionEnvelopeStore(
            load: { nil },
            save: { _ in sessionSaveAttempted = true },
            delete: { XCTFail("Identity rejection must not delete session state") }
        )
        state.configureLocalIdentityBoundary(modelContext: context, defaults: defaults)
        state.configureClientIdentityRequirement {
            throw ClientIdentityError.unavailable
        }
        let user = UserProfile(
            id: "dom",
            name: "Alex",
            email: "demo-person-39@example.invalid",
            role: "admin",
            priority: 5,
            familyId: "family",
            mustChangePassword: false
        )

        do {
            try await state.login(
                accessToken: "unpublished-access",
                refreshToken: "unpublished-refresh",
                user: user
            )
            XCTFail("Authentication must not publish without durable client identity")
        } catch ClientIdentityError.unavailable {
            // Expected.
        }

        XCTAssertFalse(sessionSaveAttempted)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.currentUser)
        XCTAssertFalse(SyncManager.shared.isIdentityActive)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<OfflineAction>()), 1)
    }

    @MainActor
    func testStoredSessionReadFailureIsSurfacedWithoutDeletion() async throws {
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        var deleteAttempted = false
        state.configureSessionEnvelopeStore(
            load: { throw KeychainError.loadFailed(errSecInteractionNotAllowed) },
            save: { _ in XCTFail("A failed read must not write a replacement session") },
            delete: { deleteAttempted = true }
        )
        state.configureLocalIdentityBoundary(modelContext: context, defaults: defaults)

        XCTAssertNotNil(state.localDataErrorMessage)
        await state.restoreSession()

        XCTAssertFalse(deleteAttempted)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.currentUser)
        XCTAssertNotNil(state.localDataErrorMessage)
    }

    @MainActor
    func testPendingFITBoundaryFailureNeverPublishesAuthentication() async throws {
        enum InjectedFailure: Error { case pendingFITBoundary }
        let previousSession = APIClient.shared.currentSessionSnapshot()
        defer { restoreSharedClientSession(previousSession) }
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        defaults.set("family:dom", forKey: AppState.localOwnerKey)
        _ = configureInMemoryAppStateSession(state)
        state.configurePendingFITIdentityActivation { _ in
            throw InjectedFailure.pendingFITBoundary
        }
        state.configureLocalIdentityBoundary(modelContext: context, defaults: defaults)
        let user = UserProfile(
            id: "dom",
            name: "Alex",
            email: "demo-person-39@example.invalid",
            role: "admin",
            priority: 5,
            familyId: "family",
            mustChangePassword: false
        )

        do {
            try await state.login(
                accessToken: "unpublished-access",
                refreshToken: "unpublished-refresh",
                user: user
            )
            XCTFail("Authentication must not publish without the durable FIT boundary")
        } catch InjectedFailure.pendingFITBoundary {
            // Expected.
        }

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.currentUser)
        XCTAssertNil(APIClient.shared.currentSessionSnapshot())
        XCTAssertNil(FitnessDatabase.shared.activeIdentity)
        XCTAssertFalse(SyncManager.shared.isIdentityActive)
        XCTAssertNotNil(state.localDataErrorMessage)
    }

    @MainActor
    func testSessionEnvelopeWriteFailureNeverPublishesAuthentication() async throws {
        enum InjectedFailure: Error { case keychainWrite }
        let previousSession = APIClient.shared.currentSessionSnapshot()
        defer {
            if let previousSession {
                APIClient.shared.installSession(
                    identity: previousSession.identity,
                    accessToken: previousSession.accessToken,
                    refreshToken: previousSession.refreshToken
                )
            } else {
                APIClient.shared.clearSession()
            }
        }
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        defaults.set("family:dom", forKey: AppState.localOwnerKey)
        var deleteAttempted = false
        state.configureSessionEnvelopeStore(
            load: { nil },
            save: { _ in throw InjectedFailure.keychainWrite },
            delete: { deleteAttempted = true }
        )
        state.configureClientIdentityRequirement {
            "00000000-0000-4000-8000-000000000001"
        }
        state.configureSharedCaptureIdentityActivation { _ in }
        state.configurePendingFITIdentityActivation { _ in }
        state.configureLocalIdentityBoundary(modelContext: context, defaults: defaults)
        let user = UserProfile(
            id: "dom",
            name: "Alex",
            email: "demo-person-39@example.invalid",
            role: "admin",
            priority: 5,
            familyId: "family",
            mustChangePassword: false
        )

        do {
            try await state.login(
                accessToken: "unpersisted-access",
                refreshToken: "unpersisted-refresh",
                user: user
            )
            XCTFail("A failed atomic session write must fail the login")
        } catch InjectedFailure.keychainWrite {
            // Expected.
        }

        XCTAssertTrue(deleteAttempted)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.currentUser)
        XCTAssertNil(APIClient.shared.currentSessionSnapshot())
    }

    @MainActor
    func testResetRequiredNeverRestoresWhenEnvelopeDeletionFails() async throws {
        enum InjectedFailure: Error { case keychainDelete }
        let state = AppState()
        let (_, context, defaults) = try identityHarness()
        defaults.set(true, forKey: AppState.localResetRequiredKey)
        var loadAttempted = false
        var deleteAttempted = false
        state.configureSessionEnvelopeStore(
            load: {
                loadAttempted = true
                return nil
            },
            save: { _ in XCTFail("Restore must not write while reset is required") },
            delete: {
                deleteAttempted = true
                throw InjectedFailure.keychainDelete
            }
        )
        state.configureLocalIdentityBoundary(modelContext: context, defaults: defaults)

        await state.restoreSession()

        XCTAssertFalse(loadAttempted)
        XCTAssertTrue(deleteAttempted)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.currentUser)
        XCTAssertTrue(defaults.bool(forKey: AppState.localResetRequiredKey))
        XCTAssertNotNil(state.localDataErrorMessage)
    }

    @MainActor
    func testStoredSessionValidationKeepsCredentialsForTransientFailuresOnly() {
        XCTAssertTrue(AppState.isTransientSessionValidationError(
            APIError.networkError(URLError(.notConnectedToInternet))
        ))
        XCTAssertTrue(AppState.isTransientSessionValidationError(
            APIError.decodingError(DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "temporary incompatible response")
            ))
        ))
        for statusCode in [408, 425, 429, 500, 503, 599] {
            XCTAssertTrue(AppState.isTransientSessionValidationError(
                APIError.serverError(statusCode: statusCode, message: nil)
            ))
        }

        XCTAssertFalse(AppState.isTransientSessionValidationError(APIError.unauthorized))
        XCTAssertFalse(AppState.isTransientSessionValidationError(APIError.forbidden))
        XCTAssertFalse(AppState.isTransientSessionValidationError(APIError.tokenRefreshFailed))
        XCTAssertFalse(AppState.isTransientSessionValidationError(
            APIError.serverError(statusCode: 400, message: "invalid")
        ))
    }

    func testFileBackedMultipartPreservesRepeatedFieldAndFileOrder() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartFiles-\(UUID().uuidString)", isDirectory: true)
        let transferRoot = workspace.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let first = workspace.appendingPathComponent("first.txt", isDirectory: false)
        let second = workspace.appendingPathComponent("second.txt", isDirectory: false)
        try Data("FIRST-FILE-CONTENT".utf8).write(to: first)
        try Data("SECOND-FILE-CONTENT".utf8).write(to: second)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let client = makeStubbedClient(transferTemporaryRoot: transferRoot) { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(CachedResponse(value: "uploaded"))
            )
        }
        defer { client.clearSession() }
        client.transferReadyBarrierForTesting = {
            do {
                let directories = try FileManager.default.contentsOfDirectory(
                    at: transferRoot,
                    includingPropertiesForKeys: nil
                )
                let directory = try XCTUnwrap(directories.first)
                let body = try Data(
                    contentsOf: directory.appendingPathComponent("request.body")
                )
                let text = try XCTUnwrap(String(data: body, encoding: .utf8))
                let firstField = try XCTUnwrap(text.range(of: "\r\nfirst\r\n"))
                let secondField = try XCTUnwrap(text.range(of: "\r\nsecond\r\n"))
                let firstFile = try XCTUnwrap(text.range(of: "FIRST-FILE-CONTENT"))
                let secondFile = try XCTUnwrap(text.range(of: "SECOND-FILE-CONTENT"))
                XCTAssertLessThan(firstField.lowerBound, secondField.lowerBound)
                XCTAssertLessThan(secondField.lowerBound, firstFile.lowerBound)
                XCTAssertLessThan(firstFile.lowerBound, secondFile.lowerBound)
            } catch {
                XCTFail("Could not inspect staged multipart body: \(error)")
            }
        }

        let result: CachedResponse = try await client.uploadMultipartFiles(
            "/documents/",
            fileFieldName: "files",
            files: [
                (filename: "first.txt", mediaType: "text/plain", fileURL: first),
                (filename: "second.txt", mediaType: "text/plain", fileURL: second),
            ],
            orderedFields: [
                (name: "tag", value: "first"),
                (name: "tag", value: "second"),
            ]
        )

        XCTAssertEqual(result.value, "uploaded")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: transferRoot.path),
            []
        )
    }

    func testFileBackedMultipartRejectsSymlinkBeforeStaging() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartSymlink-\(UUID().uuidString)", isDirectory: true)
        let transferRoot = workspace.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let target = workspace.appendingPathComponent("target.txt", isDirectory: false)
        let symlink = workspace.appendingPathComponent("link.txt", isDirectory: false)
        try Data("private".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let client = makeStubbedClient(transferTemporaryRoot: transferRoot) { _ in
            XCTFail("An invalid source must not reach transport")
            throw URLError(.badURL)
        }
        defer { client.clearSession() }

        do {
            let _: CachedResponse = try await client.uploadMultipartFiles(
                "/documents/",
                fileFieldName: "files",
                files: [(filename: "link.txt", mediaType: "text/plain", fileURL: symlink)],
                orderedFields: []
            )
            XCTFail("A symlink source must be rejected")
        } catch let error as APIClient.MultipartUploadSourceError {
            XCTAssertEqual(error, .invalidFile)
        } catch {
            XCTFail("Expected invalidFile, got \(error)")
        }
        if FileManager.default.fileExists(atPath: transferRoot.path) {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: transferRoot.path),
                []
            )
        }
    }

    func testFileBackedMultipartCapsCombinedSourcesBeforeStaging() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartLimit-\(UUID().uuidString)", isDirectory: true)
        let transferRoot = workspace.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let first = workspace.appendingPathComponent("first.bin", isDirectory: false)
        let second = workspace.appendingPathComponent("second.bin", isDirectory: false)
        let eachSize = UInt64(APIClient.maximumFileBackedMultipartSourceBytes / 2 + 1)
        for source in [first, second] {
            XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: eachSize)
            try handle.close()
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        let client = makeStubbedClient(transferTemporaryRoot: transferRoot) { _ in
            XCTFail("An oversized request must not reach transport")
            throw URLError(.badURL)
        }
        defer { client.clearSession() }

        do {
            let _: CachedResponse = try await client.uploadMultipartFiles(
                "/documents/",
                fileFieldName: "files",
                files: [
                    (filename: "first.bin", mediaType: "application/octet-stream", fileURL: first),
                    (filename: "second.bin", mediaType: "application/octet-stream", fileURL: second),
                ],
                orderedFields: []
            )
            XCTFail("The combined source cap must be enforced")
        } catch let error as APIClient.MultipartUploadSourceError {
            XCTAssertEqual(
                error,
                .requestTooLarge(maximumBytes: APIClient.maximumFileBackedMultipartSourceBytes)
            )
        } catch {
            XCTFail("Expected requestTooLarge, got \(error)")
        }
        if FileManager.default.fileExists(atPath: transferRoot.path) {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: transferRoot.path),
                []
            )
        }
    }

    func testMultipartSuccessLeavesNoProtectedTemporaryBody() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartTests-\(UUID().uuidString)", isDirectory: true)
        let transferRoot = workspace.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appendingPathComponent("large-photo.jpg")
        try Data(repeating: 0x4A, count: 2 * 1_024 * 1_024).write(to: source)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = makeStubbedClient(transferTemporaryRoot: transferRoot) { request in
            XCTAssertTrue(
                request.value(forHTTPHeaderField: "Content-Type")?
                    .hasPrefix("multipart/form-data; boundary=HausKlar-") == true
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(CachedResponse(value: "uploaded"))
            )
        }
        defer { client.clearSession() }

        let result: CachedResponse = try await client.uploadMultipart(
            "/artworks",
            fileURL: source,
            filename: "photo.jpg",
            mediaType: "image/jpeg",
            fields: ["child_id": "child-1"]
        )

        XCTAssertEqual(result.value, "uploaded")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: transferRoot.path),
            []
        )
    }

    func testMultipartCancellationRemovesStagedBodyWithoutQueueing() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartCancel-\(UUID().uuidString)", isDirectory: true)
        let transferRoot = workspace.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appendingPathComponent("photo.jpg")
        try Data(repeating: 0x21, count: 1_024 * 1_024).write(to: source)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = makeStubbedClient(transferTemporaryRoot: transferRoot) { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }
        let staged = expectation(description: "multipart body staged")
        client.transferReadyBarrierForTesting = {
            staged.fulfill()
            try? await Task.sleep(for: .seconds(30))
        }
        let upload = Task { () -> CachedResponse in
            try await client.uploadMultipart(
                "/artworks",
                fileURL: source,
                filename: "photo.jpg",
                mediaType: "image/jpeg",
                fields: [:]
            )
        }
        await fulfillment(of: [staged], timeout: 2)

        upload.cancel()

        await assertCancellation { _ = try await upload.value }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: transferRoot.path),
            []
        )
        let pendingCount = await client.pendingOfflineMutationCount()
        XCTAssertEqual(pendingCount, 0)
    }

    func testMultipartAccountReplacementRejectsResultAndCleansBody() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartIdentity-\(UUID().uuidString)", isDirectory: true)
        let transferRoot = workspace.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appendingPathComponent("photo.jpg")
        try Data(repeating: 0x32, count: 128 * 1_024).write(to: source)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = makeStubbedClient(transferTemporaryRoot: transferRoot) { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONEncoder().encode(CachedResponse(value: "wrong account"))
            )
        }
        defer { client.clearSession() }
        client.transferReadyBarrierForTesting = {
            _ = client.installSession(
                identity: "replacement-family:replacement-user",
                accessToken: "replacement-access",
                refreshToken: "replacement-refresh"
            )
        }

        do {
            let _: CachedResponse = try await client.uploadMultipart(
                "/artworks",
                fileURL: source,
                filename: "photo.jpg",
                mediaType: "image/jpeg",
                fields: [:]
            )
            XCTFail("An account-A upload must not publish under account B")
        } catch APIError.unauthorized {
            // Expected.
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: transferRoot.path),
            []
        )
    }

    func testCallerManagedMultipartNeverEntersGenericOfflineQueue() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultipartOwnedQueue-\(UUID().uuidString)", isDirectory: true)
        let transferRoot = workspace.appendingPathComponent("transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appendingPathComponent("document.pdf")
        try Data("private document".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let client = makeStubbedClient(transferTemporaryRoot: transferRoot) { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { client.clearSession() }

        do {
            let _: CachedResponse = try await client.uploadMultipart(
                "/documents/",
                fileURL: source,
                filename: "document.pdf",
                mediaType: "application/pdf",
                fields: ["document_id": UUID().uuidString],
                offlineReplayPolicy: .callerManaged
            )
            XCTFail("The feature-owned queue must receive the transport failure")
        } catch APIError.networkError {
            // Expected.
        }

        let pendingCount = await client.pendingOfflineMutationCount()
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: transferRoot.path),
            []
        )
    }

    func testInterruptedTransferReconciliationIsOldOwnedSymlinkSafeAndBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferReconcile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let old = now.addingTimeInterval(-7_200)

        let multipart = root.appendingPathComponent(
            "multipart-\(UUID().uuidString)",isDirectory: true
        )
        let download = root.appendingPathComponent(
            "download-\(UUID().uuidString)",isDirectory: true
        )
        let fresh = root.appendingPathComponent(
            "multipart-\(UUID().uuidString)",isDirectory: true
        )
        for directory in [multipart,download,fresh] {
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        }
        let multipartBody = multipart.appendingPathComponent("request.body")
        let downloadBody = download.appendingPathComponent("document.pdf")
        let freshBody = fresh.appendingPathComponent("request.body")
        for file in [multipartBody,downloadBody,freshBody] {
            try Data("private".utf8).write(to: file)
        }
        for file in [multipartBody,downloadBody] {
            try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: file.path)
            try FileManager.default.setAttributes(
                [.modificationDate: old],ofItemAtPath: file.deletingLastPathComponent().path
            )
        }

        let externalTarget = root.appendingPathComponent("provider-owned",isDirectory: true)
        try FileManager.default.createDirectory(at: externalTarget,withIntermediateDirectories: true)
        let symbolicLink = root.appendingPathComponent(
            "download-\(UUID().uuidString)",isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: symbolicLink,withDestinationURL: externalTarget)
        let malformed = root.appendingPathComponent(
            "multipart-\(UUID().uuidString)",isDirectory: true
        )
        try FileManager.default.createDirectory(at: malformed,withIntermediateDirectories: true)
        try Data().write(to: malformed.appendingPathComponent("unexpected"))
        try FileManager.default.setAttributes([.modificationDate: old],ofItemAtPath: malformed.path)

        let firstPass = APIClient.reconcileInterruptedTransfers(
            at: root,now: now,minimumAge: 3_600,
            maximumCandidates: 32,maximumRemovals: 1
        )
        XCTAssertEqual(firstPass,1)
        XCTAssertEqual(
            [multipart,download].filter { FileManager.default.fileExists(atPath: $0.path) }.count,
            1
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalTarget.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformed.path))

        XCTAssertEqual(
            APIClient.reconcileInterruptedTransfers(
                at: root,now: now,minimumAge: 3_600,
                maximumCandidates: 32,maximumRemovals: 32
            ),
            1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: multipart.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLink.path))
    }
}

final class APIClientStubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Delivers response chunks one at a time so tests can observe whether the
/// production delegate stops URL loading before a later chunk is accepted.
final class APIClientStreamingURLProtocol: URLProtocol {
    struct Script {
        let statusCode: Int
        let headers: [String: String]
        let chunks: [Data]
        let delay: TimeInterval

        init(
            statusCode: Int,
            headers: [String: String],
            chunks: [Data],
            delay: TimeInterval = 0.02
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.chunks = chunks
            self.delay = delay
        }
    }

    private static let configurationLock = NSLock()
    private static var script: Script?
    private static var onStop: (() -> Void)?
    private static var deliveredChunks = 0

    private let stateLock = NSLock()
    private var stopped = false
    private var finished = false

    static var deliveredChunkCount: Int {
        configurationLock.withLock { deliveredChunks }
    }

    static func install(script: Script, onStop: (() -> Void)? = nil) {
        configurationLock.withLock {
            self.script = script
            self.onStop = onStop
            deliveredChunks = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let script = Self.configurationLock.withLock({ Self.script }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
            url: url,
            statusCode: script.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: script.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(script: script, index: 0)
    }

    private func deliver(script: Script, index: Int) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + script.delay) {
            let shouldDeliver = self.stateLock.withLock { !self.stopped && !self.finished }
            guard shouldDeliver else { return }
            guard index < script.chunks.count else {
                self.stateLock.withLock { self.finished = true }
                self.client?.urlProtocolDidFinishLoading(self)
                return
            }
            Self.configurationLock.withLock { Self.deliveredChunks += 1 }
            self.client?.urlProtocol(self, didLoad: script.chunks[index])
            self.deliver(script: script, index: index + 1)
        }
    }

    override func stopLoading() {
        let shouldNotify = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return !finished
        }
        guard shouldNotify else { return }
        let callback = Self.configurationLock.withLock { Self.onStop }
        callback?()
    }
}

final class OfflineHTTPMutationStoreTests: XCTestCase {
    func testReviewedCommitmentInterpretationAndSearchStayNetworkOnly() {
        for path in [
            "/commitments/from-source",
            "/commitments/free-windows/query",
        ] {
            XCTAssertFalse(
                OfflineHTTPMutationStore.allows(
                    path: path,
                    method: "POST",
                    contentType: "application/json",
                    hasInlineBody: true,
                    hasBodyFile: false
                )
            )
        }
        XCTAssertTrue(
            OfflineHTTPMutationStore.allows(
                path: "/commitments/commitment-id",
                method: "PATCH",
                contentType: "application/json",
                hasInlineBody: true,
                hasBodyFile: false
            )
        )
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }
        func now() -> Date { lock.withLock { value } }
        func advance(_ interval: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(interval) }
        }
    }

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineHTTPStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func jsonMutation(
        id: String = UUID().uuidString,
        identity: String = "family:user",
        body: Data = Data(#"{"value":1}"#.utf8)
    ) -> QueuedHTTPMutation {
        QueuedHTTPMutation(
            id: id,
            identity: identity,
            method: "POST",
            path: "/dog/activities",
            body: body,
            contentType: "application/json",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func multipartMutation(
        id: String = UUID().uuidString,
        identity: String = "family:user"
    ) -> QueuedHTTPMutation {
        QueuedHTTPMutation(
            id: id,
            identity: identity,
            method: "POST",
            path: "/artworks",
            body: nil,
            contentType: "multipart/form-data; boundary=HausKlar-test",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func testRetryBackoffAuthPauseAndCancellationDoNotLoseClaims() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock(Date(timeIntervalSince1970: 10_000))
        let store = OfflineHTTPMutationStore(
            directory: directory,
            maxEncodedBytes: 20_000,
            now: clock.now,
            retryJitter: { 1 }
        )
        let mutation = jsonMutation(id: "retry")
        try await store.enqueue(mutation)

        var claimed = try await store.claimNext(identity: mutation.identity)
        _ = try XCTUnwrap(claimed)
        try await store.releaseAfterCancellation(id: mutation.id, identity: mutation.identity)
        var summaries = try await store.summaries(identity: mutation.identity)
        var summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.status, .pending)
        XCTAssertEqual(summary.retryCount, 0)

        claimed = try await store.claimNext(identity: mutation.identity)
        _ = try XCTUnwrap(claimed)
        try await store.releaseForAuthentication(id: mutation.id, identity: mutation.identity)
        summaries = try await store.summaries(identity: mutation.identity)
        summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.status, .pending)
        XCTAssertEqual(summary.retryCount, 0)

        claimed = try await store.claimNext(identity: mutation.identity)
        _ = try XCTUnwrap(claimed)
        try await store.markRetryable(
            id: mutation.id,
            identity: mutation.identity,
            error: "Server unavailable",
            statusCode: 503
        )
        summaries = try await store.summaries(identity: mutation.identity)
        summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.status, .retryable)
        XCTAssertEqual(summary.retryCount, 1)
        XCTAssertEqual(summary.nextAttemptAt, clock.now().addingTimeInterval(5))
        claimed = try await store.claimNext(identity: mutation.identity)
        XCTAssertNil(claimed)
        clock.advance(5)
        claimed = try await store.claimNext(identity: mutation.identity)
        XCTAssertNotNil(claimed)
    }

    func testProcessInterruptionRecoversInFlightClaimWithoutRetryIncrement() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mutation = jsonMutation(id: "interrupted")
        let firstProcess = OfflineHTTPMutationStore(directory: directory, maxEncodedBytes: 20_000)
        try await firstProcess.enqueue(mutation)
        let firstClaim = try await firstProcess.claimNext(identity: mutation.identity)
        _ = try XCTUnwrap(firstClaim)

        let replacementProcess = OfflineHTTPMutationStore(directory: directory, maxEncodedBytes: 20_000)
        let reclaimedValue = try await replacementProcess.claimNext(identity: mutation.identity)
        let reclaimed = try XCTUnwrap(reclaimedValue)

        XCTAssertEqual(reclaimed.id, mutation.id)
        XCTAssertEqual(reclaimed.retryCount, 0)
    }

    func testReleaseSaveFailureSurfacesAndNextProcessReclaimsClaim() async throws {
        enum InjectedFailure: Error { case save }
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeRoot = directory.appendingPathComponent("queue")
        let saveLock = NSLock()
        var saveCount = 0
        let mutation = jsonMutation(id: "release-save-failure")
        let firstProcess = OfflineHTTPMutationStore(
            directory: storeRoot,
            maxEncodedBytes: 20_000,
            saveHook: {
                let count = saveLock.withLock { () -> Int in
                    saveCount += 1
                    return saveCount
                }
                if count == 3 { throw InjectedFailure.save }
            }
        )
        try await firstProcess.enqueue(mutation)
        let firstClaim = try await firstProcess.claimNext(identity: mutation.identity)
        _ = try XCTUnwrap(firstClaim)

        do {
            try await firstProcess.releaseAfterCancellation(
                id: mutation.id,
                identity: mutation.identity
            )
            XCTFail("A failed release write must remain visible to the flush owner")
        } catch InjectedFailure.save {
            // Expected: the persisted row is still in-flight, while the failed
            // process has removed its runtime claim.
        }

        let replacementProcess = OfflineHTTPMutationStore(
            directory: storeRoot,
            maxEncodedBytes: 20_000
        )
        let reclaimedValue = try await replacementProcess.claimNext(
            identity: mutation.identity
        )
        let reclaimed = try XCTUnwrap(reclaimedValue)
        XCTAssertEqual(reclaimed.id, mutation.id)
        XCTAssertEqual(reclaimed.status, .inFlight)
        XCTAssertEqual(reclaimed.retryCount, 0)
    }

    func testQueueEnforcesItemAndActualEncodedByteCaps() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let itemLimited = OfflineHTTPMutationStore(
            directory: directory.appendingPathComponent("items"),
            maxItems: 1,
            maxEncodedBytes: 20_000
        )
        try await itemLimited.enqueue(jsonMutation(id: "one"))
        do {
            try await itemLimited.enqueue(jsonMutation(id: "two"))
            XCTFail("The item cap must reject additional durable work")
        } catch OfflineHTTPMutationStoreError.capacityExceeded {
            // Expected.
        }

        let byteLimited = OfflineHTTPMutationStore(
            directory: directory.appendingPathComponent("bytes"),
            maxItems: 10,
            maxEncodedBytes: 700
        )
        do {
            try await byteLimited.enqueue(
                jsonMutation(id: "large", body: Data(repeating: 0x41, count: 700))
            )
            XCTFail("Encoded metadata plus payload must respect the byte cap")
        } catch OfflineHTTPMutationStoreError.capacityExceeded {
            // Expected.
        }
    }

    func testAcknowledgementSaveFailureKeepsMultipartBodyReplayable() async throws {
        enum InjectedFailure: Error { case save }
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.body")
        try Data(repeating: 0x44, count: 4_096).write(to: source)
        let saveLock = NSLock()
        var saveCount = 0
        let mutation = multipartMutation(id: "durable-upload")
        let store = OfflineHTTPMutationStore(
            directory: directory.appendingPathComponent("queue"),
            maxEncodedBytes: 20_000,
            saveHook: {
                let count = saveLock.withLock { () -> Int in
                    saveCount += 1
                    return saveCount
                }
                if count == 3 { throw InjectedFailure.save }
            }
        )
        try await store.enqueue(mutation, bodyFile: source)
        let initialClaim = try await store.claimNext(identity: mutation.identity)
        _ = try XCTUnwrap(initialClaim)

        do {
            try await store.complete(id: mutation.id, identity: mutation.identity)
            XCTFail("Injected acknowledgement persistence failure must surface")
        } catch InjectedFailure.save {
            // Expected.
        }

        let replacement = OfflineHTTPMutationStore(
            directory: directory.appendingPathComponent("queue"),
            maxEncodedBytes: 20_000
        )
        let reclaimedValue = try await replacement.claimNext(identity: mutation.identity)
        let reclaimed = try XCTUnwrap(reclaimedValue)
        let durableBodyValue = try await replacement.bodyFileURL(for: reclaimed)
        let durableBody = try XCTUnwrap(durableBodyValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableBody.path))
        XCTAssertEqual(
            try durableBody.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            4_096
        )
    }

    func testTamperedPathAndBodyFilenameFailClosed() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeRoot = directory.appendingPathComponent("queue")
        let store = OfflineHTTPMutationStore(directory: storeRoot, maxEncodedBytes: 20_000)
        let mutation = jsonMutation(id: "tampered")
        try await store.enqueue(mutation)
        let identityDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: storeRoot,
                includingPropertiesForKeys: nil
            ).first { $0.hasDirectoryPath }
        )
        let metadata = identityDirectory.appendingPathComponent("queue.json")
        var array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [[String: Any]]
        )
        array[0]["path"] = "https://attacker.example/delete"
        try JSONSerialization.data(withJSONObject: array).write(to: metadata, options: .atomic)

        let relaunched = OfflineHTTPMutationStore(directory: storeRoot, maxEncodedBytes: 20_000)
        do {
            _ = try await relaunched.summaries(identity: mutation.identity)
            XCTFail("Absolute/tampered paths must never be replayable")
        } catch OfflineHTTPMutationStoreError.corruptStore {
            // Expected.
        }

        let bodyStoreRoot = directory.appendingPathComponent("body-queue")
        let bodyStore = OfflineHTTPMutationStore(
            directory: bodyStoreRoot,
            maxEncodedBytes: 20_000
        )
        let source = directory.appendingPathComponent("upload-source")
        try Data("private upload".utf8).write(to: source)
        let upload = multipartMutation(id: "tampered-body")
        try await bodyStore.enqueue(upload, bodyFile: source)
        let bodyIdentityDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: bodyStoreRoot,
                includingPropertiesForKeys: nil
            ).first { $0.hasDirectoryPath }
        )
        let bodyMetadata = bodyIdentityDirectory.appendingPathComponent("queue.json")
        var bodyArray = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: bodyMetadata))
                as? [[String: Any]]
        )
        bodyArray[0]["bodyFileName"] = "../../outside.body"
        try JSONSerialization.data(withJSONObject: bodyArray)
            .write(to: bodyMetadata, options: .atomic)

        let bodyRelaunch = OfflineHTTPMutationStore(
            directory: bodyStoreRoot,
            maxEncodedBytes: 20_000
        )
        do {
            _ = try await bodyRelaunch.summaries(identity: upload.identity)
            XCTFail("Tampered body filenames must never be resolved")
        } catch OfflineHTTPMutationStoreError.corruptStore {
            // Expected.
        }
    }

    func testOrphanAndInterruptedStagingBodiesAreReconciled() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeRoot = directory.appendingPathComponent("queue")
        let store = OfflineHTTPMutationStore(directory: storeRoot, maxEncodedBytes: 20_000)
        let mutation = jsonMutation(id: "kept")
        try await store.enqueue(mutation)
        let identityDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: storeRoot,
                includingPropertiesForKeys: nil
            ).first { $0.hasDirectoryPath }
        )
        let orphan = identityDirectory.appendingPathComponent("orphan.body")
        let staging = identityDirectory.appendingPathComponent(".staging-interrupted")
        let providerTarget = directory.appendingPathComponent("provider-owned")
        let bodyLink = identityDirectory.appendingPathComponent("linked.body")
        let stagingLink = identityDirectory.appendingPathComponent(".staging-provider")
        try Data("orphan".utf8).write(to: orphan)
        try Data("staging".utf8).write(to: staging)
        try Data("must survive".utf8).write(to: providerTarget)
        try FileManager.default.createSymbolicLink(at: bodyLink,withDestinationURL: providerTarget)
        try FileManager.default.createSymbolicLink(at: stagingLink,withDestinationURL: providerTarget)

        _ = try await store.summaries(identity: mutation.identity)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyLink.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingLink.path))
        XCTAssertEqual(try Data(contentsOf: providerTarget),Data("must survive".utf8))
    }

    func testQueueMetadataRejectsOversizedAndSymlinkedFilesBeforeDecode() async throws {
        let directory = try workspace()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeRoot = directory.appendingPathComponent("queue")
        let mutation = jsonMutation(id: "bounded-metadata")
        let store = OfflineHTTPMutationStore(directory: storeRoot,maxEncodedBytes: 4_096)
        try await store.enqueue(mutation)
        let identityDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: storeRoot,includingPropertiesForKeys: nil
            ).first { $0.hasDirectoryPath }
        )
        let metadata = identityDirectory.appendingPathComponent("queue.json")
        let validMetadata = try Data(contentsOf: metadata)
        let handle = try FileHandle(forWritingTo: metadata)
        try handle.truncate(atOffset: 4_097)
        try handle.close()

        let oversized = OfflineHTTPMutationStore(directory: storeRoot,maxEncodedBytes: 4_096)
        do {
            _ = try await oversized.summaries(identity: mutation.identity)
            XCTFail("Oversized queue metadata must fail before decoding")
        } catch OfflineHTTPMutationStoreError.corruptStore {
            // Expected.
        }

        try FileManager.default.removeItem(at: metadata)
        let providerTarget = directory.appendingPathComponent("provider-queue.json")
        try validMetadata.write(to: providerTarget)
        try FileManager.default.createSymbolicLink(at: metadata,withDestinationURL: providerTarget)
        let symlinked = OfflineHTTPMutationStore(directory: storeRoot,maxEncodedBytes: 4_096)
        do {
            _ = try await symlinked.summaries(identity: mutation.identity)
            XCTFail("Symlinked queue metadata must fail closed")
        } catch OfflineHTTPMutationStoreError.corruptStore {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: providerTarget),validMetadata)
    }
}

private final class RemovalFailingFileManager: FileManager {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

final class FileCacheTests: XCTestCase {

    private func protection(at url: URL) throws -> String? {
#if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return LocalFileProtection.sensitive.rawValue
#else
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.protectionKey] as? String
#endif
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testMemoryTierServesDataAfterDiskFileIsRemoved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(cacheDir: directory)
        let key = "https://example.test/api/tasks"
        let data = Data("cached".utf8)

        await cache.set(key, data: data)
        let fileName = await cache.cacheKey(for: key)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))

        let result = await cache.get(key)
        XCTAssertEqual(result?.data, data)
        XCTAssertEqual(result?.isStale, false)
    }

    func testCacheReportsStaleDataWithinFallbackWindow() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(cacheDir: directory, ttl: -1, staleTTL: 60)

        await cache.set("key", data: Data("value".utf8))

        let result = await cache.get("key")
        XCTAssertEqual(result?.isStale, true)
    }

    func testClearRemovesMemoryAndDiskEntries() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(cacheDir: directory)

        await cache.set("key", data: Data("value".utf8))
        await cache.clear()

        let result = await cache.get("key")
        XCTAssertNil(result)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testSecurePurgeSurfacesDiskDeletionFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(cacheDir: directory)
        await cache.set("account-a", data: Data("private payload".utf8))

        do {
            try await cache.securePurge(fileManager: RemovalFailingFileManager())
            XCTFail("Identity-boundary purge must fail closed when cache deletion fails")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
            )
        }
    }

    func testDiskTierUsesCompleteFileProtection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileCache(cacheDir: directory)
        let key = "https://example.test/api/health"

        await cache.set(key, data: Data("private response".utf8))

        let filename = await cache.cacheKey(for: key)
        XCTAssertEqual(
            try protection(at: directory.appendingPathComponent(filename)),
            FileProtectionType.complete.rawValue
        )
        XCTAssertEqual(try protection(at: directory), FileProtectionType.complete.rawValue)
    }

    func testDiskTierPrunesExpiredAndOverBudgetFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let expired = directory.appendingPathComponent("expired")
        try Data("old".utf8).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: expired.path
        )
        let cache = FileCache(
            cacheDir: directory,
            staleTTL: 60,
            maxDiskBytes: 8,
            maxDiskEntries: 2,
            pruneEveryWrites: 1
        )

        await cache.set("first", data: Data("123456".utf8))
        await cache.set("second", data: Data("abcdef".utf8))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let payloadFiles = files.filter { !$0.hasPrefix(".") }
        XCTAssertEqual(payloadFiles.count, 1)
        XCTAssertFalse(files.contains("expired"))
    }

    func testTargetedInvalidationRestoresKeysFromPriorLaunchIndex() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskKey = "https://example.test/api/tasks?page=1#auth=family"
        let calendarKey = "https://example.test/api/calendar?page=1#auth=family"
        let firstLaunch = FileCache(cacheDir: directory)
        await firstLaunch.set(taskKey, data: Data("task".utf8))
        await firstLaunch.set(calendarKey, data: Data("event".utf8))

        let relaunched = FileCache(cacheDir: directory)
        await relaunched.remove { $0.contains("/tasks") }

        let verifiedRelaunch = FileCache(cacheDir: directory)
        let removedTask = await verifiedRelaunch.get(taskKey)
        let retainedCalendar = await verifiedRelaunch.get(calendarKey)
        XCTAssertNil(removedTask)
        XCTAssertEqual(retainedCalendar?.data, Data("event".utf8))
    }

    func testCorruptDurableIndexFailsClosedAndRemovesPayloads() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = "https://example.test/api/medicine#auth=family"
        let firstLaunch = FileCache(cacheDir: directory)
        await firstLaunch.set(key, data: Data("private medicine data".utf8))
        let index = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.contains("cache-index") }
        )
        try Data("not-json".utf8).write(to: index, options: .atomic)

        let relaunched = FileCache(cacheDir: directory)

        let restored = await relaunched.get(key)
        XCTAssertNil(restored)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testSymlinkedCachePayloadFailsClosedWithoutReadingTarget() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let external = directory.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID().uuidString)")
        try Data("private target".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        let key = "https://example.test/api/private#auth=family"
        let firstLaunch = FileCache(cacheDir: directory)
        await firstLaunch.set(key, data: Data("cached payload".utf8))
        let filename = await firstLaunch.cacheKey(for: key)
        let payload = directory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: external)

        let relaunched = FileCache(cacheDir: directory)

        let restored = await relaunched.get(key)
        XCTAssertNil(restored)
        XCTAssertEqual(try Data(contentsOf: external), Data("private target".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testQuotaMetadataSurvivesRelaunchWithoutDirectoryScanSemantics() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstLaunch = FileCache(
            cacheDir: directory,
            maxDiskBytes: 9,
            maxDiskEntries: 2,
            pruneEveryWrites: 100
        )
        await firstLaunch.set("oldest", data: Data("123456".utf8))
        await firstLaunch.set("newest", data: Data("abcdef".utf8))

        let relaunched = FileCache(
            cacheDir: directory,
            maxDiskBytes: 9,
            maxDiskEntries: 2,
            pruneEveryWrites: 100
        )

        let oldest = await relaunched.get("oldest")
        let newest = await relaunched.get("newest")
        XCTAssertNil(oldest)
        XCTAssertEqual(newest?.data, Data("abcdef".utf8))
    }

    func testSQLiteStoreAndSidecarsUseCompleteFileProtection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        let wal = directory.appendingPathComponent("default.store-wal")
        try Data("store".utf8).write(to: store)
        try Data("wal".utf8).write(to: wal)

        try LocalFileProtection.protectSQLiteStore(at: store)

        XCTAssertEqual(try protection(at: store), FileProtectionType.complete.rawValue)
        XCTAssertEqual(try protection(at: wal), FileProtectionType.complete.rawValue)
        XCTAssertEqual(try protection(at: directory), FileProtectionType.complete.rawValue)
    }

    func testUnreadableStoreIsArchivedWithItsSidecars() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        let wal = URL(fileURLWithPath: store.path + "-wal")
        let shm = URL(fileURLWithPath: store.path + "-shm")
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        let sourceData: [(URL, Data)] = [
            (store, Data("store".utf8)),
            (wal, Data("wal".utf8)),
            (shm, Data("shm".utf8)),
        ]
        for (url, data) in sourceData {
            try data.write(to: url)
        }

        let archived = try LocalStoreRecovery.archiveStore(
            at: store,
            recoveryRoot: recovery
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm.path))
        for (url, data) in sourceData {
            let copy = archived.appendingPathComponent(url.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: copy), data)
            XCTAssertEqual(try protection(at: copy), FileProtectionType.complete.rawValue)
        }

        let manifestURL = archived.appendingPathComponent(LocalStoreRecovery.manifestFilename)
        let manifest = try JSONDecoder().decode(
            LocalStoreRecovery.ArchiveManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.originalStoreBasename, "default.store")
        XCTAssertEqual(
            manifest.members.map(\.filename),
            ["default.store", "default.store-wal", "default.store-shm"]
        )
        for (url, data) in sourceData {
            let member = try XCTUnwrap(
                manifest.members.first { $0.filename == url.lastPathComponent }
            )
            XCTAssertEqual(member.byteCount, UInt64(data.count))
            XCTAssertEqual(member.sha256, sha256Hex(data))
        }
        XCTAssertEqual(try protection(at: recovery), FileProtectionType.complete.rawValue)
        XCTAssertEqual(try protection(at: archived), FileProtectionType.complete.rawValue)
        XCTAssertEqual(try protection(at: manifestURL), FileProtectionType.complete.rawValue)

        try LocalStoreRecovery.purgeArchives(recoveryRoot: recovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testRecoveryFailuresBeforePublishLeaveSourcesUntouchedAndCleanStaging() throws {
        let failingSteps: [LocalStoreRecovery.ArchiveStep] = [
            .beforeCopy("default.store-wal"),
            .beforeProtection("default.store"),
            .beforePublish,
        ]

        for failingStep in failingSteps {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = directory.appendingPathComponent("default.store")
            let wal = URL(fileURLWithPath: store.path + "-wal")
            let shm = URL(fileURLWithPath: store.path + "-shm")
            let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
            let sources: [(URL, Data)] = [
                (store, Data("store".utf8)),
                (wal, Data("wal".utf8)),
                (shm, Data("shm".utf8)),
            ]
            for (url, data) in sources { try data.write(to: url) }

            XCTAssertThrowsError(
                try LocalStoreRecovery.archiveStore(
                    at: store,
                    recoveryRoot: recovery,
                    failureInjector: { step in
                        if step == failingStep { throw CocoaError(.fileWriteUnknown) }
                    }
                ),
                "Expected failure at \(failingStep)"
            )

            for (url, data) in sources {
                XCTAssertEqual(try Data(contentsOf: url), data, "Source changed at \(failingStep)")
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: recovery.path),
                [],
                "Staging survived failure at \(failingStep)"
            )
        }
    }

    func testPartialSourceCleanupKeepsVerifiedArchiveAndReportsRemainingMember() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        let wal = URL(fileURLWithPath: store.path + "-wal")
        let shm = URL(fileURLWithPath: store.path + "-shm")
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try Data("store".utf8).write(to: store)
        try Data("wal".utf8).write(to: wal)
        try Data("shm".utf8).write(to: shm)

        var publishedArchive: URL?
        XCTAssertThrowsError(
            try LocalStoreRecovery.archiveStore(
                at: store,
                recoveryRoot: recovery,
                failureInjector: { step in
                    if step == .beforeSourceRemoval("default.store-wal") {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
            )
        ) { error in
            guard case LocalStoreRecovery.ArchiveError.sourceCleanupFailed(
                let archiveURL,
                let remaining
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            publishedArchive = archiveURL
            XCTAssertEqual(remaining, ["default.store-wal"])
        }

        let archive = try XCTUnwrap(publishedArchive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent(name).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shm.path))
    }

    func testRecoveryArchiveRotationRetainsThreeIncludingNewest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("default.store")
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        var newest: URL?

        for index in 0..<5 {
            try Data("store-\(index)".utf8).write(to: store)
            newest = try LocalStoreRecovery.archiveStore(at: store, recoveryRoot: recovery)
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(newest).path))
        }

        let archiveDirectories = try FileManager.default.contentsOfDirectory(
            at: recovery,
            includingPropertiesForKeys: nil
        ).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        XCTAssertEqual(archiveDirectories.count, LocalStoreRecovery.retainedArchiveCount)
        XCTAssertTrue(archiveDirectories.contains(try XCTUnwrap(newest)))
        for archive in archiveDirectories {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: archive.appendingPathComponent(LocalStoreRecovery.manifestFilename).path
                )
            )
        }
    }

    func testRecoveryRejectsSymlinkSourcesAndRecoveryRoots() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let realStore = directory.appendingPathComponent("real.store")
        let linkedStore = directory.appendingPathComponent("default.store")
        let realRecovery = directory.appendingPathComponent("real-recovery", isDirectory: true)
        let linkedRecovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try Data("store".utf8).write(to: realStore)
        try FileManager.default.createSymbolicLink(at: linkedStore, withDestinationURL: realStore)
        try FileManager.default.createDirectory(at: realRecovery, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRecovery, withDestinationURL: realRecovery)

        XCTAssertThrowsError(
            try LocalStoreRecovery.archiveStore(at: linkedStore, recoveryRoot: realRecovery)
        )
        XCTAssertThrowsError(
            try LocalStoreRecovery.archiveStore(at: realStore, recoveryRoot: linkedRecovery)
        )
        XCTAssertEqual(try Data(contentsOf: realStore), Data("store".utf8))
    }

    func testRecoveryArchivePurgeSurfacesDeletionFailure() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recovery = directory.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try Data("private store".utf8).write(
            to: recovery.appendingPathComponent("default.store")
        )

        XCTAssertThrowsError(
            try LocalStoreRecovery.purgeArchives(
                recoveryRoot: recovery,
                fileManager: RemovalFailingFileManager()
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }
}

final class KeychainProtectionTests: XCTestCase {

    private var userJSON: String {
        #"{"id":"dom","name":"Alex","email":"demo-person-39@example.invalid","role":"admin","priority":5,"familyId":"family","mustChangePassword":false}"#
    }

    private var envelope: StoredSessionEnvelope {
        StoredSessionEnvelope(
            identity: "family:dom",
            accessToken: "access",
            refreshToken: "refresh",
            userJSON: userJSON
        )
    }

    func testSessionSecretsAreWhenUnlockedAndDeviceOnly() {
        let expected = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

        XCTAssertEqual(
            KeychainManager.accessibility(for: KeychainManager.Keys.accessToken) as String,
            expected
        )
        XCTAssertEqual(
            KeychainManager.accessibility(for: KeychainManager.Keys.refreshToken) as String,
            expected
        )
        XCTAssertEqual(
            KeychainManager.accessibility(for: KeychainManager.Keys.currentUser) as String,
            expected
        )
        XCTAssertEqual(
            KeychainManager.accessibility(for: KeychainManager.Keys.sessionEnvelope) as String,
            expected
        )
    }

    func testClientIdRemainsAvailableAfterFirstUnlockButDeviceOnly() {
        XCTAssertEqual(
            KeychainManager.accessibility(for: KeychainManager.Keys.clientId) as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testExistingValidClientIdIsReusedWithoutWrite() throws {
        let existing = "55dca57e-5cf4-41df-9c3c-bfed68b8eeb4"
        var saveAttempted = false

        let value = try KeychainManager.getOrCreateClientId(
            loadItem: { key in
                XCTAssertEqual(key, KeychainManager.Keys.clientId)
                return existing
            },
            saveItem: { _, _ in
                saveAttempted = true
                return true
            }
        )

        XCTAssertEqual(value, existing)
        XCTAssertFalse(saveAttempted)
    }

    func testMalformedExistingClientIdFailsClosedWithoutReplacement() {
        var saveAttempted = false

        XCTAssertThrowsError(
            try KeychainManager.getOrCreateClientId(
                loadItem: { _ in "legacy-device-name" },
                saveItem: { _, _ in
                    saveAttempted = true
                    return true
                }
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityError, .malformedStoredIdentifier)
        }
        XCTAssertFalse(saveAttempted)
    }

    func testClientIdSaveFailureNeverReturnsGeneratedIdentity() {
        let generated = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        var loadCount = 0

        XCTAssertThrowsError(
            try KeychainManager.getOrCreateClientId(
                loadItem: { _ in
                    loadCount += 1
                    return nil
                },
                saveItem: { _, _ in throw KeychainError.saveFailed(errSecNotAvailable) },
                generate: { generated }
            )
        ) { error in
            guard case KeychainError.saveFailed(let status) = error,
                  status == errSecNotAvailable else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(loadCount, 1, "A failed write must not be treated as verified")
    }

    func testClientIdReadBackMismatchFailsVerification() {
        let generated = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        let different = "30000000-0000-4000-8000-000000000003"
        var loadCount = 0

        XCTAssertThrowsError(
            try KeychainManager.getOrCreateClientId(
                loadItem: { _ in
                    loadCount += 1
                    return loadCount == 1 ? nil : different
                },
                saveItem: { _, _ in true },
                generate: { generated }
            )
        ) { error in
            XCTAssertEqual(error as? ClientIdentityError, .persistenceNotVerified)
        }
        XCTAssertEqual(loadCount, 2)
    }

    func testClientIdReadBackFailureIsNotCollapsedIntoMissing() {
        let generated = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
        var loadCount = 0

        XCTAssertThrowsError(
            try KeychainManager.getOrCreateClientId(
                loadItem: { _ in
                    loadCount += 1
                    if loadCount == 1 { return nil }
                    throw KeychainError.loadFailed(errSecInteractionNotAllowed)
                },
                saveItem: { _, _ in true },
                generate: { generated }
            )
        ) { error in
            guard case KeychainError.loadFailed(let status) = error,
                  status == errSecInteractionNotAllowed else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(loadCount, 2)
    }

    func testMigrationUpdatesAllExistingItemClasses() {
        var migrated: [String: String] = [:]

        KeychainManager.migrateStoredItemProtection { key, accessibility in
            migrated[key] = accessibility as String
            return errSecSuccess
        }

        XCTAssertEqual(migrated.count, 5)
        XCTAssertEqual(
            migrated[KeychainManager.Keys.accessToken],
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            migrated[KeychainManager.Keys.refreshToken],
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            migrated[KeychainManager.Keys.clientId],
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testLegacyTripletMigratesOnlyAfterVerifiedAtomicEnvelopeWrite() throws {
        var items = [
            KeychainManager.Keys.accessToken: "access",
            KeychainManager.Keys.refreshToken: "refresh",
            KeychainManager.Keys.currentUser: userJSON,
        ]

        let migrated = try KeychainManager.loadSessionEnvelope(
            loadItem: { items[$0] },
            saveItem: { key, value in
                items[key] = value
                return true
            },
            deleteItem: { key in
                items[key] = nil
                return true
            }
        )

        XCTAssertEqual(migrated, envelope)
        XCTAssertNotNil(items[KeychainManager.Keys.sessionEnvelope])
        XCTAssertNil(items[KeychainManager.Keys.accessToken])
        XCTAssertNil(items[KeychainManager.Keys.refreshToken])
        XCTAssertNil(items[KeychainManager.Keys.currentUser])
    }

    func testLegacyMigrationWriteFailureKeepsCompleteLegacyTriplet() {
        enum InjectedFailure: Error { case write }
        var items = [
            KeychainManager.Keys.accessToken: "access",
            KeychainManager.Keys.refreshToken: "refresh",
            KeychainManager.Keys.currentUser: userJSON,
        ]

        XCTAssertThrowsError(
            try KeychainManager.loadSessionEnvelope(
                loadItem: { items[$0] },
                saveItem: { _, _ in throw InjectedFailure.write },
                deleteItem: { key in
                    items[key] = nil
                    return true
                }
            )
        )
        XCTAssertEqual(items[KeychainManager.Keys.accessToken], "access")
        XCTAssertEqual(items[KeychainManager.Keys.refreshToken], "refresh")
        XCTAssertEqual(items[KeychainManager.Keys.currentUser], userJSON)
        XCTAssertNil(items[KeychainManager.Keys.sessionEnvelope])
    }

    func testEnvelopeReadbackFailureNeverDeletesLegacyCredentials() {
        var items = [
            KeychainManager.Keys.accessToken: "access",
            KeychainManager.Keys.refreshToken: "refresh",
            KeychainManager.Keys.currentUser: userJSON,
        ]

        XCTAssertThrowsError(
            try KeychainManager.loadSessionEnvelope(
                loadItem: { items[$0] },
                saveItem: { key, _ in
                    items[key] = "corrupt"
                    return true
                },
                deleteItem: { key in
                    items[key] = nil
                    return true
                }
            )
        )
        XCTAssertEqual(items[KeychainManager.Keys.accessToken], "access")
        XCTAssertEqual(items[KeychainManager.Keys.refreshToken], "refresh")
        XCTAssertEqual(items[KeychainManager.Keys.currentUser], userJSON)
    }

    func testVerifiedEnvelopeCleanupFailureRemainsVisibleAndRetryable() throws {
        enum InjectedFailure: Error { case cleanup }
        let encoded = try XCTUnwrap(
            String(data: try JSONEncoder().encode(envelope), encoding: .utf8)
        )
        var items = [KeychainManager.Keys.sessionEnvelope: encoded]

        XCTAssertThrowsError(
            try KeychainManager.loadSessionEnvelope(
                loadItem: { items[$0] },
                saveItem: { _, _ in
                    XCTFail("An authoritative envelope must not be rewritten")
                    return true
                },
                deleteItem: { key in
                    if key == KeychainManager.Keys.refreshToken {
                        throw InjectedFailure.cleanup
                    }
                    items[key] = nil
                    return true
                }
            )
        ) { error in
            guard case InjectedFailure.cleanup = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(items[KeychainManager.Keys.sessionEnvelope], encoded)
    }

    func testIncompleteLegacyStateFailsClosedWithoutMigration() {
        let items = [
            KeychainManager.Keys.accessToken: "account-a-access",
            KeychainManager.Keys.currentUser: userJSON,
        ]

        XCTAssertThrowsError(
            try KeychainManager.loadSessionEnvelope(
                loadItem: { items[$0] },
                saveItem: { _, _ in
                    XCTFail("Incomplete state must not be written")
                    return true
                },
                deleteItem: { _ in
                    XCTFail("Incomplete state must not be deleted")
                    return true
                }
            )
        )
    }

    func testAuthoritativeEnvelopeDeleteFailureStopsBeforeLegacyCleanup() {
        enum InjectedFailure: Error { case delete }
        var attemptedKeys: [String] = []

        XCTAssertThrowsError(
            try KeychainManager.deleteSessionEnvelope { key in
                attemptedKeys.append(key)
                throw InjectedFailure.delete
            }
        )
        XCTAssertEqual(attemptedKeys, [KeychainManager.Keys.sessionEnvelope])
    }

    func testWidgetSessionReadFailureFailsClosed() {
        let token = KeychainManager.sessionAccessToken { key in
            XCTAssertEqual(key, KeychainManager.Keys.sessionEnvelope)
            throw KeychainError.loadFailed(errSecInteractionNotAllowed)
        }

        XCTAssertNil(token)
    }

    func testLegacyHomeAssistantCleanupContinuesAfterOneDeleteFailure() {
        enum InjectedFailure: Error { case delete }
        var attemptedKeys: [String] = []

        KeychainManager.deleteLegacyHomeAssistantCredentials { key in
            attemptedKeys.append(key)
            if attemptedKeys.count == 1 { throw InjectedFailure.delete }
            return true
        }

        XCTAssertEqual(attemptedKeys.count, 2)
        XCTAssertEqual(Set(attemptedKeys).count, 2)
    }
}
