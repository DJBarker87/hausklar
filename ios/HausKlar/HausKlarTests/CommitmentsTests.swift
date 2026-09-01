import XCTest
@testable import HausKlar

final class CommitmentsTests: XCTestCase {
    func testTravelContractKeepsMultipleEventsAndUsesEarliestUrgency() throws {
        let commitment = try Self.decodeCommitment(Self.commitmentJSON)

        XCTAssertEqual(commitment.kind, .travel)
        XCTAssertEqual(commitment.plan.events.map(\.title), ["Train to London", "Hotel stay"])
        XCTAssertEqual(commitment.plan.preparations.first?.items, ["Passports", "Chargers"])
        XCTAssertEqual(commitment.plan.externalAction?.handoffURL?.scheme, "https")
        XCTAssertEqual(
            commitment.urgency,
            ISODateParser.parse("2026-09-03")
        )
        XCTAssertEqual(commitment.temporalUrgency?.precision, .dateOnly)
        let rendered = try XCTUnwrap(commitment.temporalUrgency).formatted(
            locale: Locale(identifier: "en_GB")
        )
        XCTAssertFalse(rendered.contains(":"), "A date-only deadline must not invent a time")
        XCTAssertFalse(commitment.canConfirm(currentUserId: "owner-user"))

        var ready = commitment
        ready.externalActionStatus = .completed
        XCTAssertTrue(ready.canConfirm(currentUserId: "owner-user"))
    }

    func testFromSourceSendsInitialOwnerVisibilitySupersessionAndStableOperationID() async throws {
        let recorder = CommitmentRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(url.path, "/api/commitments/from-source")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(Self.fromSourceJSON.utf8))
        }
        let client = Self.makeClient()
        defer { client.clearSession() }
        let service = CommitmentService(apiClient: client)
        let operationID = "10000000-0000-4000-8000-000000000001"

        let result = try await service.createFromSource(
            kind: .school,
            visibility: .owner,
            title: "  Sports day  ",
            reviewedText: "  Bring PE kit on Friday.  ",
            sourceDocumentId: nil,
            sourceLabel: "  School email  ",
            providerReference: " MSG-42 ",
            supersedesId: "earlier-school-plan",
            requestHermes: true,
            aiConsentAllowsHermes: false,
            metadata: CommitmentMutationMetadata(
                id: operationID,
                timestamp: "2026-08-12T12:00:00Z"
            ),
            timezone: "Europe/London"
        )

        XCTAssertEqual(result.processor, "deterministic")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-HausKlar-Operation-ID"),
            operationID
        )
        let body = try Self.jsonBody(request)
        XCTAssertEqual(body["id"] as? String, operationID)
        XCTAssertEqual(body["text"] as? String, "Bring PE kit on Friday.")
        XCTAssertEqual(body["source_label"] as? String, "School email")
        XCTAssertEqual(body["provider_reference"] as? String, "MSG-42")
        XCTAssertEqual(body["use_hermes"] as? Bool, false)
        XCTAssertEqual(body["visibility"] as? String, "owner")
        XCTAssertEqual(body["supersedes_id"] as? String, "earlier-school-plan")
        XCTAssertEqual(body["timezone"] as? String, "Europe/London")
        XCTAssertEqual(body["client_id"] as? String, Self.clientID)
    }

    func testOpenCommitmentsRequestsServerSideOpenOnlyFilter() async throws {
        let recorder = CommitmentRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(url.path, "/api/commitments")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("[\(Self.commitmentJSON)]".utf8))
        }
        let client = Self.makeClient()
        defer { client.clearSession() }

        let result = try await CommitmentService(apiClient: client)
            .openCommitments(refresh: true)

        XCTAssertEqual(result.value.map(\.id), ["commitment-1"])
        let request = try XCTUnwrap(recorder.requests.first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(query["open_only"]!, "true")
        XCTAssertEqual(query["limit"]!, "100")
    }

    func testSupersedingPlanDecodesProminentReviewItems() throws {
        let value = Self.commitmentJSON.replacingOccurrences(
            of: #""supersedes_id":null,"change_summary":[]"#,
            with: #""supersedes_id":"earlier-trip","change_summary":["Event details or times changed","Actions or deadlines changed"]"#
        )

        let commitment = try Self.decodeCommitment(value)

        XCTAssertEqual(commitment.supersedesId, "earlier-trip")
        XCTAssertEqual(
            commitment.updateReviewItems,
            ["Event details or times changed", "Actions or deadlines changed"]
        )
    }

    func testAllSourceCreationRoutesUseReviewedSourceEndpoint() async throws {
        let recorder = CommitmentRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(Self.fromSourceJSON.utf8))
        }
        let client = Self.makeClient()
        defer { client.clearSession() }
        let service = CommitmentService(apiClient: client)
        let kinds: [CommitmentKind] = [.school, .invitation, .appointment, .travel]

        for (index, kind) in kinds.enumerated() {
            _ = try await service.createFromSource(
                kind: kind,
                visibility: .family,
                title: kind.title,
                reviewedText: "Reviewed source for \(kind.rawValue)",
                sourceDocumentId: nil,
                sourceLabel: "Test source",
                providerReference: nil,
                supersedesId: nil,
                requestHermes: false,
                aiConsentAllowsHermes: false,
                metadata: CommitmentMutationMetadata(
                    id: String(format: "30000000-0000-4000-8000-%012d", index + 1),
                    timestamp: "2026-08-12T12:10:00Z"
                )
            )
        }

        XCTAssertEqual(recorder.requests.count, kinds.count)
        for (request, kind) in zip(recorder.requests, kinds) {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/commitments/from-source")
            let body = try Self.jsonBody(request)
            XCTAssertEqual(body["kind"] as? String, kind.rawValue)
            XCTAssertEqual(body["visibility"] as? String, "family")
        }
    }

    func testTypedOutingAndChildcareRoutesSendInitialVisibilityAndAcceptDedupeResponse() async throws {
        let recorder = CommitmentRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: recorder.requests.count == 3 ? 200 : 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            // Semantic replay is intentionally an ordinary success containing
            // the already-created commitment, even when the retry has a new ID.
            return (response, Data(Self.commitmentJSON.utf8))
        }
        let client = Self.makeClient()
        defer { client.clearSession() }
        let service = CommitmentService(apiClient: client)
        let kinds: [CommitmentKind] = [.outing, .childcare, .outing]

        var results: [Commitment] = []
        for (index, kind) in kinds.enumerated() {
            let value = try await service.create(
                kind: kind,
                visibility: .owner,
                title: "Typed \(kind.rawValue)",
                summary: "Same reviewed typed request",
                sources: [
                    CommitmentSource(
                        id: String(format: "40000000-0000-4000-8000-%012d", index + 1),
                        kind: .manual,
                        documentId: nil,
                        label: "Typed test",
                        providerReference: nil,
                        sourceUrl: nil,
                        observedAt: "2026-08-12T12:15:00Z"
                    )
                ],
                plan: .empty,
                groupKey: nil,
                metadata: CommitmentMutationMetadata(
                    id: String(format: "50000000-0000-4000-8000-%012d", index + 1),
                    timestamp: "2026-08-12T12:15:00Z"
                )
            )
            results.append(value)
        }

        XCTAssertEqual(results.map(\.id), ["commitment-1", "commitment-1", "commitment-1"])
        XCTAssertEqual(recorder.requests.count, 3)
        for (request, kind) in zip(recorder.requests, kinds) {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/commitments")
            let body = try Self.jsonBody(request)
            XCTAssertEqual(body["kind"] as? String, kind.rawValue)
            XCTAssertEqual(body["visibility"] as? String, "owner")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "X-HausKlar-Operation-ID"),
                body["id"] as? String
            )
        }
    }

    @MainActor
    func testSupersessionCandidatesExcludeCurrentPlanAndWrongKind() async throws {
        let recorder = CommitmentRequestRecorder()
        let school = Self.commitmentJSON
            .replacingOccurrences(of: #""id":"commitment-1""#, with: #""id":"school-1""#)
            .replacingOccurrences(of: #""kind":"travel""#, with: #""kind":"school""#)
        let anotherSchool = school.replacingOccurrences(
            of: #""id":"school-1""#,
            with: #""id":"school-2""#
        )
        let privateSchool = school
            .replacingOccurrences(of: #""id":"school-1""#, with: #""id":"school-private""#)
            .replacingOccurrences(of: #""visibility":"family""#, with: #""visibility":"owner""#)
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                Data("[\(school),\(anotherSchool),\(privateSchool),\(Self.commitmentJSON)]".utf8)
            )
        }
        let client = Self.makeClient()
        defer { client.clearSession() }
        let viewModel = CommitmentsViewModel(service: CommitmentService(apiClient: client))
        viewModel.configure(currentUserId: "owner-user")

        await viewModel.loadPending(refresh: true)

        XCTAssertEqual(
            viewModel.supersessionCandidates(
                for: .school,
                visibility: .family,
                excluding: "school-1"
            ).map(\.id),
            ["school-2"]
        )
        XCTAssertEqual(
            viewModel.supersessionCandidates(for: .school, visibility: .owner).map(\.id),
            ["school-private"]
        )
    }

    func testNonOwnerUpdateOmitsVisibilityButPreservesRevisionAndOperationID() async throws {
        let recorder = CommitmentRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(url.path, "/api/commitments/commitment-1")
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(Self.commitmentJSON.utf8))
        }
        let client = Self.makeClient()
        defer { client.clearSession() }
        let service = CommitmentService(apiClient: client)
        let original = try Self.decodeCommitment(Self.commitmentJSON)
        var edited = original
        edited.visibility = .owner
        edited.title = "Updated trip"
        let operationID = "20000000-0000-4000-8000-000000000002"

        _ = try await service.update(
            original: original,
            draft: edited,
            mayChangeVisibility: false,
            metadata: CommitmentMutationMetadata(
                id: operationID,
                timestamp: "2026-08-12T12:05:00Z"
            )
        )

        let request = try XCTUnwrap(recorder.requests.first)
        let body = try Self.jsonBody(request)
        XCTAssertNil(body["visibility"])
        XCTAssertEqual(body["expected_revision"] as? Int, 4)
        XCTAssertEqual(body["title"] as? String, "Updated trip")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-HausKlar-Operation-ID"),
            operationID
        )
    }

    private static let clientID = "00000000-0000-4000-8000-000000000001"

    private static func makeClient() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { clientID }
        )
        client.baseURL = "https://commitments-\(UUID().uuidString).example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        return client
    }

    private static func decodeCommitment(_ value: String) throws -> Commitment {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Commitment.self, from: Data(value.utf8))
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                as? [String: Any]
        )
    }

    private static let commitmentJSON = #"""
    {
      "id":"commitment-1","kind":"travel","visibility":"family",
      "owner_user_id":"owner-user","title":"Family trip","summary":"Two linked bookings",
      "status":"ready","revision":4,
      "sources":[{"id":"source-1","kind":"provider","document_id":null,"label":"Rail booking","provider_reference":"ABC123","source_url":"https://rail.example.test/booking","observed_at":"2026-08-12T10:00:00Z"}],
      "plan":{
        "events":[
          {"id":"event-1","title":"Train to London","description":null,"start_time":"2026-09-04T09:00:00Z","end_time":"2026-09-04T10:00:00Z","all_day":false,"location":"Station","person_ids":["child-1"],"affected_adult_ids":["owner-user"],"assigned_to":"owner-user","event_type":"travel","document_ids":[]},
          {"id":"event-2","title":"Hotel stay","description":null,"start_time":"2026-09-04","end_time":"2026-09-06","all_day":true,"location":"London","person_ids":["child-1"],"affected_adult_ids":[],"assigned_to":null,"event_type":"travel","document_ids":[]}
        ],
        "tasks":[{"id":"task-1","title":"Check tickets","description":null,"due_date":"2026-09-03","actionable_from":"2026-09-01","assigned_to":"owner-user","priority":3,"document_id":null}],
        "preparations":[{"id":"prep-1","event_id":"event-1","name":"Pack","items":["Passports","Chargers"],"lead_hours":24,"assigned_to":"owner-user"}],
        "external_action":{"kind":"book","label":"Open booking","target_type":"https","target":"https://rail.example.test/booking","due_at":"2026-09-03T08:00:00Z","requires_completion_before_confirm":true}
      },
      "review_issues":[],"external_action_status":"pending","external_action_outcome":null,
      "external_action_completed_at":null,"group_key":"trip-london","interpretation_processor":"deterministic",
      "supersedes_id":null,"change_summary":[],"confirmed_at":null,"declined_at":null,"results":[],
      "created_at":"2026-08-12T10:00:00Z","updated_at":"2026-08-12T10:00:00Z",
      "created_by":"owner-user","client_id":"client-1","client_timestamp":"2026-08-12T10:00:00Z"
    }
    """#

    private static let fromSourceJSON = #"""
    {
      "commitment":\#(commitmentJSON),
      "processor":"deterministic","warning":null,"deduplicated":false,"material_changes":[]
    }
    """#
}

private final class CommitmentRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { storage } }

    func append(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil,
           let stream = captured.httpBodyStream,
           let body = Self.read(stream) {
            captured.httpBody = body
        }
        lock.withLock { storage.append(captured) }
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
