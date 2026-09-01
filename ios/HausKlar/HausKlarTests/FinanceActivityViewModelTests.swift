import XCTest
@testable import HausKlar

final class FinanceWebRouterTests: XCTestCase {
    func testConfiguredRouteKeepsScopeAndOpaqueRecordIdentifier() throws {
        let router = try XCTUnwrap(
            FinanceWebRouter(baseURL: URL(string: "https://money.example.test")!)
        )

        let url = try XCTUnwrap(
            router.url(
                section: "activity",
                scope: .household,
                mode: "full",
                recordQueryItems: [URLQueryItem(name: "line", value: "line/with spaces")]
            )
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )

        XCTAssertEqual(components.host, "money.example.test")
        XCTAssertEqual(components.queryItems?.first { $0.name == "view" }?.value, "finance")
        XCTAssertEqual(components.queryItems?.first { $0.name == "section" }?.value, "activity")
        XCTAssertEqual(components.queryItems?.first { $0.name == "scope" }?.value, "household")
        XCTAssertEqual(components.queryItems?.first { $0.name == "line" }?.value, "line/with spaces")
        XCTAssertFalse(url.absoluteString.contains("token"))
    }

    func testRelativeFinanceLinkIsPreservedAndExternalLinkIsRejected() throws {
        let router = try XCTUnwrap(
            FinanceWebRouter(baseURL: URL(string: "https://money.example.test")!)
        )

        XCTAssertEqual(
            router.url(
                relativeFinanceDeepLink: "/?view=finance&section=plan&scope=household&commitment=c-1"
            )?.absoluteString,
            "https://money.example.test/?view=finance&section=plan&scope=household&commitment=c-1"
        )
        XCTAssertNil(
            router.url(relativeFinanceDeepLink: "https://attacker.example/?view=finance")
        )
        XCTAssertNil(router.url(relativeFinanceDeepLink: "/?view=fitness"))
        XCTAssertNil(
            router.url(relativeFinanceDeepLink: "/?view=fitness&view=finance")
        )
    }

    func testEnvironmentCanConfigureDevelopmentWebAddress() throws {
        let router = try XCTUnwrap(
            FinanceWebRouter.configured(
                environment: ["FINANCE_WEB_BASE_URL": "http://localhost:5173"]
            )
        )
        XCTAssertEqual(router.baseURL.absoluteString, "http://localhost:5173/")
        XCTAssertNil(FinanceWebRouter(baseURL: URL(string: "http://example.test")!))
    }

    func testPurchaseSummaryAndDetailDecodeFromServerContract() throws {
        let summaryJSON = #"""
        {
          "id":"purchase-1","space_id":"personal-current","merchant":"Example retailer",
          "item_descriptions":["School shoes"],"order_reference":"ORDER-1",
          "purchased_on":"2026-08-02","currency":"GBP","lines_subtotal_minor":4500,
          "shipping_minor":0,"vat_included_minor":750,"order_discount_minor":0,
          "final_total_minor":4500,"refunded_minor":0,"behavioural_net_minor":4500,
          "status":"fulfilled","source_kind":"e_receipt","match_status":"MATCHED",
          "unmatched_purchase_minor":0,"unmatched_refund_minor":0,
          "cashflow_source":"canonical_transactions","purchase_total_added_to_cashflow":false,
          "supersedes_purchase_id":null,"superseded_by_id":null,
          "created_at":"2026-08-02T12:01:00Z"
        }
        """#
        let detailJSON = #"""
        {
          "id":"purchase-1","space_id":"personal-current","merchant":"Example retailer",
          "item_descriptions":["School shoes"],"order_reference":"ORDER-1",
          "purchased_on":"2026-08-02","currency":"GBP","lines_subtotal_minor":4500,
          "shipping_minor":0,"vat_included_minor":750,"order_discount_minor":0,
          "final_total_minor":4500,"refunded_minor":0,"behavioural_net_minor":4500,
          "status":"fulfilled","source_kind":"e_receipt","match_status":"MATCHED",
          "unmatched_purchase_minor":0,"unmatched_refund_minor":0,
          "cashflow_source":"canonical_transactions","purchase_total_added_to_cashflow":false,
          "supersedes_purchase_id":null,"superseded_by_id":null,
          "created_at":"2026-08-02T12:01:00Z",
          "evidence":{
            "id":"evidence-1","space_id":"personal-current","external_source_id":"source-1",
            "source_kind":"e_receipt","corrects_source_id":null,"parser_version":"1",
            "extraction_status":"PARSED","confidence_bps":9500,"raw_payload":{},"issues":[],
            "storage_area":"finance-evidence","storage_key":null,"provider_message_id":null,
            "visible_sender":null,"email_subject":null,"files":[],
            "received_at":"2026-08-02T12:00:00Z","parsed_at":"2026-08-02T12:01:00Z",
            "created_at":"2026-08-02T12:00:00Z"
          },
          "lines":[{
            "id":"line-1","line_ref":"1","position":1,"line_kind":"product",
            "raw_description":"School shoes","quantity_decimal":"1","unit_description":"pair",
            "unit_price_minor":4500,"line_gross_minor":4500,"line_discount_minor":0,
            "line_net_minor":4500,"evidence_status":"observed_document","source_refs":[],
            "seller":"Example retailer","product_reference":null,"replaces_description":null,
            "shipment_reference":null
          }],
          "tenders":[],"refunds":[],"payment_allocations":[]
        }
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let summary = try decoder.decode(
            FinancePurchaseRecordDTO.self,
            from: Data(summaryJSON.utf8)
        )
        let detail = try decoder.decode(
            FinancePurchaseRecordDTO.self,
            from: Data(detailJSON.utf8)
        )

        XCTAssertEqual(summary.itemDescriptions, ["School shoes"])
        XCTAssertEqual(summary.sourceKind, "e_receipt")
        XCTAssertNil(summary.evidence)
        XCTAssertNil(summary.lines)
        XCTAssertEqual(detail.evidence?.extractionStatus, "PARSED")
        XCTAssertEqual(detail.lines?.first?.rawDescription, "School shoes")
    }

    func testTransactionClassificationDecodesAndHasHonestFallback() throws {
        let json = #"""
        [{
          "id":"transaction-1","space_id":"personal-current","account_id":"account-1",
          "canonical_date":"2026-08-08","amount_minor":-3245,"currency":"GBP",
          "state":"POSTED","transaction_kind":"CARD","source_kind":"BANK",
          "description":"SUPERMARKET","merchant_text":"Village Grocer","merchant_id":null,
          "primary_category_id":"example-category","primary_category_name":"Quinn",
          "primary_spending_type":"FLEXIBLE","superseded_by_id":null,
          "data_through_at":"2026-08-09T08:00:00Z","relations":[],
          "splits":[{
            "id":"split-1","transaction_id":"transaction-1","amount_minor":-2000,
            "category_id":"example-category","category_name":"Quinn",
            "spending_type":"FLEXIBLE","label":null,
            "created_at":"2026-08-09T08:01:00Z"
          },{
            "id":"split-2","transaction_id":"transaction-1","amount_minor":-1245,
            "category_id":null,"category_name":"Uncategorised",
            "spending_type":"UNCATEGORISED","label":"Other items",
            "created_at":"2026-08-09T08:01:01Z"
          }]
        },{
          "id":"transaction-2","space_id":"personal-current","account_id":"account-1",
          "canonical_date":"2026-08-09","amount_minor":-1299,"currency":"GBP",
          "state":"POSTED","transaction_kind":"CARD","source_kind":"BANK",
          "description":"UNKNOWN","merchant_text":null,"merchant_id":null,
          "primary_category_id":null,"primary_category_name":null,
          "primary_spending_type":"UNCATEGORISED","superseded_by_id":null,
          "data_through_at":"2026-08-09T08:00:00Z","relations":[],"splits":[]
        }]
        """#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let transactions = try decoder.decode(
            [FinanceTransactionDTO].self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(transactions[0].classificationDisplayName, "Quinn")
        XCTAssertEqual(transactions[0].primarySpendingType, "FLEXIBLE")
        XCTAssertEqual(transactions[0].splits.map(\.categoryName), ["Quinn", "Uncategorised"])
        XCTAssertEqual(transactions[0].splits.map(\.spendingType), ["FLEXIBLE", "UNCATEGORISED"])
        XCTAssertEqual(transactions[0].activityClassificationDisplayName, "Split · 2 categories")
        XCTAssertNil(transactions[0].activityClassificationSpendingType)
        XCTAssertEqual(transactions[1].classificationDisplayName, "Uncategorised")
        XCTAssertEqual(transactions[1].activityClassificationDisplayName, "Uncategorised")
        XCTAssertEqual(transactions[1].activityClassificationSpendingType, "UNCATEGORISED")
    }
}

@MainActor
final class FinanceActivityViewModelTests: XCTestCase {
    func testTrueLayerStartSendsTheSelectedSpaceAndIOSClient() async throws {
        let recorder = FinanceBankRequestRecorder()
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
                Data(#"{"redirect_url":"https://auth.truelayer.com/session/test"}"#.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        defer { client.clearSession() }

        let api = LiveFinanceBankConnectionAPI(client: client)
        let redirect = try await api.startBankConnection(
            spaceId: "personal-current",
            connectionId: nil
        )

        XCTAssertEqual(redirect.absoluteString, "https://auth.truelayer.com/session/test")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/finance/connections/truelayer/start")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(object, ["space_id": "personal-current", "client": "ios"])
    }

    func testTrueLayerReauthorizationSendsTheExistingConnectionId() async throws {
        let recorder = FinanceBankRequestRecorder()
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
                Data(#"{"redirect_url":"https://auth.truelayer.com/session/reauth"}"#.utf8)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        defer { client.clearSession() }

        let api = LiveFinanceBankConnectionAPI(client: client)
        _ = try await api.startBankConnection(
            spaceId: "personal-current",
            connectionId: "connection-1"
        )

        let request = try XCTUnwrap(recorder.requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(object, [
            "space_id": "personal-current",
            "client": "ios",
            "connection_id": "connection-1",
        ])
    }

    func testFetchingBankConnectionsUsesTheSelectedSpaceAndDecodesStatus() async throws {
        let recorder = FinanceBankRequestRecorder()
        APIClientStubURLProtocol.install { request in
            recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"[{"id":"connection-1","space_id":"personal-current","can_manage":true,"provider":"TRUELAYER","institution":"NatWest","status":"REAUTH_REQUIRED"}]"#
            return (response, Data(body.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIClientStubURLProtocol.self]
        let client = APIClient(
            sessionConfiguration: configuration,
            resolveClientId: { "00000000-0000-4000-8000-000000000001" }
        )
        client.baseURL = "https://api.example.test/api"
        _ = client.installSession(
            identity: "family-a:user-a",
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        defer { client.clearSession() }

        let api = LiveFinanceBankConnectionAPI(client: client)
        let connections = try await api.fetchConnections(spaceId: "personal-current")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/finance/connections")
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "space_id" })?.value,
            "personal-current"
        )
        XCTAssertEqual(connections.first?.id, "connection-1")
        XCTAssertEqual(connections.first?.institution, "NatWest")
        XCTAssertTrue(connections.first?.canManage == true)
        XCTAssertTrue(connections.first?.canReconnectInApp == true)
    }

    func testTrueLayerAuthorizationAddressMustBeTheExactSecureHost() {
        XCTAssertTrue(FinanceBankConnectionCoordinator.isAllowedAuthorizationURL(
            URL(string: "https://auth.truelayer.com/session/test")!
        ))
        for value in [
            "http://auth.truelayer.com/session/test",
            "https://auth.truelayer.com.attacker.example/session/test",
            "https://user:demo-person-7@example.invalid/session/test",
            "https://auth.truelayer.com:443/session/test",
            "https://auth.truelayer.com:444/session/test",
            "https://auth.truelayer.com./session/test",
        ] {
            XCTAssertFalse(
                FinanceBankConnectionCoordinator.isAllowedAuthorizationURL(URL(string: value)!),
                value
            )
        }
    }

    func testFinanceBankCallbackMustMatchTheFixedAppAddress() {
        XCTAssertEqual(
            FinanceBankConnectionCoordinator.outcome(
                forCallbackURL: URL(string: "hausklar://finance-bank?bank=connected")!
            ),
            .connected
        )
        XCTAssertEqual(
            FinanceBankConnectionCoordinator.outcome(
                forCallbackURL: URL(string: "hausklar://finance-bank?bank=cancelled")!
            ),
            .cancelled
        )
        XCTAssertEqual(
            FinanceBankConnectionCoordinator.outcome(
                forCallbackURL: URL(string: "hausklar://finance-bank?bank=failed")!
            ),
            .failed
        )

        for value in [
            "https://finance-bank?bank=connected",
            "hausklar://other?bank=connected",
            "hausklar://finance-bank/?bank=connected",
            "hausklar://finance-bank?bank=unknown",
            "hausklar://finance-bank?bank=connected&extra=1",
            "hausklar://user:password@finance-bank?bank=connected",
        ] {
            XCTAssertNil(
                FinanceBankConnectionCoordinator.outcome(forCallbackURL: URL(string: value)!),
                value
            )
        }
    }

    func testCoordinatorUsesTheHausKlarCallbackScheme() async {
        let start = FinanceBankConnectionStartMock(
            redirect: URL(string: "https://auth.truelayer.com/session/test")!
        )
        let authentication = FinanceBankAuthenticatorMock(
            result: .callback(URL(string: "hausklar://finance-bank?bank=connected")!)
        )
        let coordinator = FinanceBankConnectionCoordinator(
            api: start,
            authenticationSession: authentication
        )

        let outcome = await coordinator.connect(
            spaceId: "personal-current",
            connectionId: nil
        )

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(start.connectRequests, [
            .init(spaceId: "personal-current", connectionId: nil),
        ])
        XCTAssertEqual(authentication.openedURLs.map(\.absoluteString), [
            "https://auth.truelayer.com/session/test",
        ])
        XCTAssertEqual(authentication.callbackSchemes, ["hausklar"])
    }

    func testMyFinancesLoadsOnlyCurrentAdultAndHouseholdWithoutPooling() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "My finances", isDefault: true),
            FinanceSpaceDTO(id: "personal-adult-b", kind: "PERSONAL", name: "Jordan", isDefault: false),
            FinanceSpaceDTO(id: "household", kind: "HOUSEHOLD", name: "Household", isDefault: false),
        ]
        api.accountsBySpace["personal-current"] = [account(id: "mine", spaceId: "personal-current")]
        api.accountsBySpace["household"] = [account(id: "shared", spaceId: "household")]

        let viewModel = FinanceActivityViewModel(
            api: api,
            bankConnectionCoordinator: FinanceBankConnectionCoordinatorMock()
        )
        await viewModel.load()

        XCTAssertEqual(viewModel.snapshots.map(\.space.id), ["personal-current", "household"])
        XCTAssertEqual(viewModel.snapshots.map { $0.accounts.map(\.id) }, [["mine"], ["shared"]])
        XCTAssertFalse(api.requests.contains { $0.spaceId == "personal-adult-b" })
        XCTAssertTrue(api.requests.filter { $0.spaceId == "personal-current" }.allSatisfy {
            !$0.excludeOwnSharedCopies
        })
        XCTAssertTrue(api.requests.filter { $0.spaceId == "household" }.allSatisfy {
            $0.excludeOwnSharedCopies
        })
        XCTAssertNil(viewModel.errorMessage)
    }

    func testActivityModeSkipsReceiptEndpointsAndStillShowsTransactions() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(
                id: "personal-current",
                kind: "PERSONAL",
                name: "My finances",
                isDefault: true
            ),
        ]
        api.accountsBySpace["personal-current"] = [
            account(id: "current-account", spaceId: "personal-current"),
        ]
        api.transactionsBySpace["personal-current"] = [
            transaction(id: "bank-transaction", spaceId: "personal-current"),
        ]
        api.failingKinds = ["inbox", "purchases"]
        let bank = FinanceBankConnectionCoordinatorMock()
        let viewModel = FinanceActivityViewModel(
            loadMode: .activity,
            api: api,
            bankConnectionCoordinator: bank
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.snapshots.first?.transactions.map(\.id), ["bank-transaction"])
        XCTAssertEqual(Set(api.requests.map(\.kind)), Set(["accounts", "transactions"]))
        XCTAssertTrue(viewModel.snapshots.first?.purchaseInbox.isEmpty == true)
        XCTAssertTrue(viewModel.snapshots.first?.purchases.isEmpty == true)
        XCTAssertTrue(bank.fetchRequests.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testNeutralMovementRequiresConfirmedAllowlistedRelation() {
        let proposedTransfer = transaction(
            id: "proposed",
            spaceId: "personal-current",
            relations: [relation(type: "INTERNAL_TRANSFER", status: "PROPOSED")]
        )
        let confirmedFX = transaction(
            id: "confirmed-fx",
            spaceId: "personal-current",
            relations: [relation(type: "FX_LEG", status: "CONFIRMED")]
        )
        let confirmedOther = transaction(
            id: "confirmed-other",
            spaceId: "personal-current",
            relations: [relation(type: "POSSIBLE_DUPLICATE", status: "CONFIRMED")]
        )

        XCTAssertFalse(proposedTransfer.isConfirmedNeutralMovement)
        XCTAssertTrue(confirmedFX.isConfirmedNeutralMovement)
        XCTAssertFalse(confirmedOther.isConfirmedNeutralMovement)
    }

    func testHouseholdScopeRequestsSharedRecordsOnly() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "My finances", isDefault: true),
            FinanceSpaceDTO(id: "household", kind: "HOUSEHOLD", name: "Household", isDefault: false),
        ]
        api.accountsBySpace["household"] = [
            account(id: "shared-by-current-adult", spaceId: "household"),
        ]
        let viewModel = FinanceActivityViewModel(
            initialScope: .household,
            api: api,
            bankConnectionCoordinator: FinanceBankConnectionCoordinatorMock()
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.snapshots.map(\.space.id), ["household"])
        XCTAssertEqual(viewModel.snapshots.first?.accounts.map(\.id), ["shared-by-current-adult"])
        XCTAssertEqual(Set(api.requests.map(\.spaceId)), Set(["household"]))
        XCTAssertTrue(api.requests.allSatisfy { !$0.excludeOwnSharedCopies })
    }

    func testOneUnavailableSpaceLeavesTheOtherVisibleAndShowsWarning() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "My finances", isDefault: true),
            FinanceSpaceDTO(id: "household", kind: "HOUSEHOLD", name: "Household", isDefault: false),
        ]
        api.failingSpaceIds = ["household"]
        let viewModel = FinanceActivityViewModel(
            api: api,
            bankConnectionCoordinator: FinanceBankConnectionCoordinatorMock()
        )

        await viewModel.load()

        XCTAssertEqual(viewModel.snapshots.map(\.space.id), ["personal-current"])
        XCTAssertEqual(
            viewModel.errorMessage,
            "Part of Finance could not load. You can still use what is shown."
        )
    }

    func testSuccessfulBankConnectionReloadsOnlyTheSelectedFinanceSpace() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "My finances", isDefault: true),
            FinanceSpaceDTO(id: "household", kind: "HOUSEHOLD", name: "Household", isDefault: false),
        ]
        api.accountsBySpace["personal-current"] = [
            account(id: "existing", spaceId: "personal-current"),
        ]
        api.accountsBySpace["household"] = [
            account(id: "shared", spaceId: "household"),
        ]
        let bank = FinanceBankConnectionCoordinatorMock(outcomes: [.connected])
        let viewModel = FinanceActivityViewModel(
            api: api,
            bankConnectionCoordinator: bank
        )
        await viewModel.load()
        XCTAssertEqual(viewModel.bankConnectionSpaceId, "personal-current")

        api.requests.removeAll()
        api.accountsBySpace["personal-current"] = [
            account(id: "existing", spaceId: "personal-current"),
            account(id: "new-bank-account", spaceId: "personal-current"),
        ]
        await viewModel.connectBank(spaceId: "personal-current")

        XCTAssertEqual(bank.connectRequests, [
            .init(spaceId: "personal-current", connectionId: nil),
        ])
        XCTAssertEqual(
            viewModel.snapshots.first(where: { $0.space.id == "personal-current" })?.accounts.map(\.id),
            ["existing", "new-bank-account"]
        )
        XCTAssertEqual(
            viewModel.snapshots.first(where: { $0.space.id == "household" })?.accounts.map(\.id),
            ["shared"]
        )
        XCTAssertEqual(api.requests.count, 4)
        XCTAssertTrue(api.requests.allSatisfy { $0.spaceId == "personal-current" })
        XCTAssertTrue(api.requests.allSatisfy(\.forceRefresh))
        XCTAssertEqual(viewModel.bankConnectionMessage, "Bank connected.")
    }

    func testReauthorizationUsesTheSavedTrueLayerRowInsteadOfStartingAgain() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "My finances", isDefault: true),
        ]
        api.accountsBySpace["personal-current"] = [
            account(id: "existing", spaceId: "personal-current"),
        ]
        let trueLayer = bankConnection(
            id: "connection-1",
            provider: "TRUELAYER",
            status: "REAUTH_REQUIRED"
        )
        let legacy = bankConnection(
            id: "legacy-1",
            provider: "ENABLE_BANKING",
            status: "EXPIRED"
        )
        let bank = FinanceBankConnectionCoordinatorMock(outcomes: [.connected])
        bank.connectionsBySpace["personal-current"] = [trueLayer, legacy]
        let viewModel = FinanceActivityViewModel(
            api: api,
            bankConnectionCoordinator: bank
        )
        await viewModel.load()

        await viewModel.connectBank(spaceId: "personal-current")
        XCTAssertTrue(bank.connectRequests.isEmpty)

        await viewModel.connectBank(
            spaceId: "personal-current",
            connectionId: "connection-1"
        )

        XCTAssertEqual(bank.connectRequests, [
            .init(spaceId: "personal-current", connectionId: "connection-1"),
        ])
        XCTAssertTrue(viewModel.bankConnections.first(where: { $0.id == "connection-1" })?.canReconnectInApp == true)
        XCTAssertFalse(viewModel.bankConnections.first(where: { $0.id == "legacy-1" })?.canReconnectInApp ?? true)
        XCTAssertEqual(viewModel.snapshots.first?.accounts.map(\.id), ["existing"])
    }

    func testAnotherAdultsHouseholdBankStaysHistoryOnlyAndDoesNotBlockAddBank() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(
                id: "household",
                kind: "HOUSEHOLD",
                name: "Household",
                isDefault: false
            ),
        ]
        api.accountsBySpace["household"] = [
            account(id: "shared-existing", spaceId: "household"),
        ]
        let otherAdultsConnection = bankConnection(
            id: "other-adult-bank",
            provider: "TRUELAYER",
            status: "EXPIRED",
            spaceId: "household",
            canManage: false
        )
        let bank = FinanceBankConnectionCoordinatorMock(outcomes: [.cancelled])
        bank.connectionsBySpace["household"] = [otherAdultsConnection]
        let viewModel = FinanceActivityViewModel(
            initialScope: .household,
            api: api,
            bankConnectionCoordinator: bank
        )
        await viewModel.load()

        XCTAssertEqual(viewModel.bankConnectionSpaceId, "household")
        XCTAssertTrue(viewModel.bankConnections.first?.isHistoricalReadOnly == true)
        XCTAssertEqual(viewModel.bankConnections.first?.statusLabel, "History only")
        XCTAssertFalse(viewModel.bankConnections.first?.canReconnectInApp ?? true)

        await viewModel.connectBank(spaceId: "household")

        XCTAssertEqual(bank.connectRequests, [
            .init(spaceId: "household", connectionId: nil),
        ])
        XCTAssertEqual(viewModel.snapshots.first?.accounts.map(\.id), ["shared-existing"])
    }

    func testCancellingBankConnectionIsQuietAndKeepsDisplayedRecords() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "My finances", isDefault: true),
        ]
        api.accountsBySpace["personal-current"] = [
            account(id: "existing", spaceId: "personal-current"),
        ]
        let bank = FinanceBankConnectionCoordinatorMock(outcomes: [.cancelled])
        let connection = bankConnection(
            id: "connection-1",
            provider: "TRUELAYER",
            status: "EXPIRED"
        )
        bank.connectionsBySpace["personal-current"] = [connection]
        let viewModel = FinanceActivityViewModel(
            api: api,
            bankConnectionCoordinator: bank
        )
        await viewModel.load()
        let displayedSnapshots = viewModel.snapshots
        let displayedConnections = viewModel.bankConnections
        api.requests.removeAll()
        api.accountsBySpace["personal-current"] = []

        await viewModel.connectBank(
            spaceId: "personal-current",
            connectionId: connection.id
        )

        XCTAssertEqual(viewModel.snapshots, displayedSnapshots)
        XCTAssertEqual(viewModel.bankConnections, displayedConnections)
        XCTAssertTrue(api.requests.isEmpty)
        XCTAssertNil(viewModel.bankConnectionMessage)
        XCTAssertFalse(viewModel.isConnectingBank)
    }

    func testFailedBankConnectionKeepsDisplayedRecordsAndUsesPlainCopy() async {
        let api = FinanceActivityAPIMock()
        api.spaces = [
            FinanceSpaceDTO(id: "personal-current", kind: "PERSONAL", name: "My finances", isDefault: true),
        ]
        api.accountsBySpace["personal-current"] = [
            account(id: "existing", spaceId: "personal-current"),
        ]
        let bank = FinanceBankConnectionCoordinatorMock(outcomes: [.failed])
        let connection = bankConnection(
            id: "connection-1",
            provider: "TRUELAYER",
            status: "DISCONNECTED"
        )
        bank.connectionsBySpace["personal-current"] = [connection]
        let viewModel = FinanceActivityViewModel(
            api: api,
            bankConnectionCoordinator: bank
        )
        await viewModel.load()
        let displayedSnapshots = viewModel.snapshots
        let displayedConnections = viewModel.bankConnections
        api.requests.removeAll()

        await viewModel.connectBank(
            spaceId: "personal-current",
            connectionId: connection.id
        )

        XCTAssertEqual(viewModel.snapshots, displayedSnapshots)
        XCTAssertEqual(viewModel.bankConnections, displayedConnections)
        XCTAssertTrue(api.requests.isEmpty)
        XCTAssertEqual(viewModel.bankConnectionMessage, "Couldn’t connect the bank. Try again.")
        XCTAssertFalse(viewModel.bankConnectionMessage?.localizedCaseInsensitiveContains("stale") ?? true)
        XCTAssertFalse(viewModel.bankConnectionMessage?.localizedCaseInsensitiveContains("URL") ?? true)
        XCTAssertFalse(viewModel.bankConnectionMessage?.localizedCaseInsensitiveContains("TrueLayer") ?? true)
    }

    func testPurchaseDetailKeepsObservedLinesAndEvidenceStatus() async throws {
        let api = FinanceActivityAPIMock()
        api.purchaseDetails["purchase-1"] = purchase(id: "purchase-1")
        let viewModel = FinancePurchaseDetailViewModel(purchaseId: "purchase-1", api: api)

        await viewModel.load()

        let loaded = try XCTUnwrap(viewModel.purchase)
        XCTAssertEqual(loaded.lines?.map(\.rawDescription), ["School shoes"])
        XCTAssertEqual(loaded.lines?.first?.evidenceStatus, "observed_document")
        XCTAssertEqual(loaded.evidence?.extractionStatus, "PARSED")
        XCTAssertNil(viewModel.errorMessage)
    }

    private func account(id: String, spaceId: String) -> FinanceAccountSummaryDTO {
        FinanceAccountSummaryDTO(
            id: id,
            spaceId: spaceId,
            label: id,
            institution: "Test Bank",
            accountType: "CURRENT",
            purpose: "SPENDING",
            currency: "GBP",
            lastFour: "1234",
            includeInCashflow: true,
            includeInNetWorth: true,
            primarySpendingAccount: false,
            minimumBalanceMinor: 0,
            freshThroughDate: "2026-08-03",
            dataThroughAt: "2026-08-03T08:00:00Z",
            balance: FinanceBalanceDTO(
                bookedMinor: 10_000,
                availableMinor: 9_500,
                creditLimitMinor: nil,
                providerAt: "2026-08-03T08:00:00Z",
                observedAt: "2026-08-03T08:00:00Z"
            )
        )
    }

    private func transaction(
        id: String,
        spaceId: String,
        relations: [FinanceRelationDTO] = []
    ) -> FinanceTransactionDTO {
        FinanceTransactionDTO(
            id: id,
            spaceId: spaceId,
            accountId: "current-account",
            canonicalDate: "2026-08-09",
            amountMinor: -3_245,
            currency: "GBP",
            state: "POSTED",
            transactionKind: "CARD",
            sourceKind: "BANK",
            description: "SUPERMARKET",
            merchantText: "Village Grocer",
            merchantId: nil,
            primaryCategoryId: "example-category",
            primaryCategoryName: "Quinn",
            primarySpendingType: "FLEXIBLE",
            supersededById: nil,
            dataThroughAt: "2026-08-09T08:00:00Z",
            relations: relations,
            splits: []
        )
    }

    private func relation(type: String, status: String) -> FinanceRelationDTO {
        FinanceRelationDTO(
            id: UUID().uuidString,
            fromTransactionId: "from",
            toTransactionId: "to",
            relationType: type,
            status: status,
            method: "TEST",
            confidenceBps: 9_000
        )
    }

    private func bankConnection(
        id: String,
        provider: String,
        status: String,
        spaceId: String = "personal-current",
        canManage: Bool = true
    ) -> FinanceBankConnectionDTO {
        FinanceBankConnectionDTO(
            id: id,
            spaceId: spaceId,
            canManage: canManage,
            provider: provider,
            institution: "Test Bank",
            status: status
        )
    }

    private func purchase(id: String) -> FinancePurchaseRecordDTO {
        FinancePurchaseRecordDTO(
            id: id,
            spaceId: "personal-current",
            merchant: "Example retailer",
            itemDescriptions: ["School shoes"],
            orderReference: "ORDER-1",
            purchasedOn: "2026-08-02",
            currency: "GBP",
            finalTotalMinor: 4_500,
            refundedMinor: 0,
            behaviouralNetMinor: 4_500,
            status: "fulfilled",
            sourceKind: "e_receipt",
            matchStatus: "MATCHED",
            unmatchedPurchaseMinor: 0,
            unmatchedRefundMinor: 0,
            evidence: FinancePurchaseEvidenceSummaryDTO(
                id: "evidence-1",
                sourceKind: "e_receipt",
                extractionStatus: "PARSED",
                confidenceBps: 9_500,
                receivedAt: "2026-08-02T12:00:00Z",
                parsedAt: "2026-08-02T12:01:00Z"
            ),
            lines: [
                FinancePurchaseLineDTO(
                    id: "line-1",
                    lineRef: "1",
                    position: 1,
                    lineKind: "product",
                    rawDescription: "School shoes",
                    quantityDecimal: "1",
                    unitDescription: "pair",
                    unitPriceMinor: 4_500,
                    lineGrossMinor: 4_500,
                    lineDiscountMinor: 0,
                    lineNetMinor: 4_500,
                    evidenceStatus: "observed_document",
                    seller: "Example retailer",
                    productReference: nil
                ),
            ],
            createdAt: "2026-08-02T12:01:00Z"
        )
    }
}

@MainActor
private final class FinanceActivityAPIMock: FinanceActivityAPI {
    struct Request: Equatable {
        let kind: String
        let spaceId: String
        let excludeOwnSharedCopies: Bool
        let forceRefresh: Bool
    }

    var spaces: [FinanceSpaceDTO] = []
    var accountsBySpace: [String: [FinanceAccountSummaryDTO]] = [:]
    var transactionsBySpace: [String: [FinanceTransactionDTO]] = [:]
    var inboxBySpace: [String: [FinancePurchaseEvidenceInboxItemDTO]] = [:]
    var purchasesBySpace: [String: [FinancePurchaseRecordDTO]] = [:]
    var purchaseDetails: [String: FinancePurchaseRecordDTO] = [:]
    var failingSpaceIds: Set<String> = []
    var failingKinds: Set<String> = []
    var requests: [Request] = []

    func fetchSpaces(forceRefresh: Bool) async throws -> [FinanceSpaceDTO] { spaces }

    func fetchAccounts(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinanceAccountSummaryDTO] {
        try record("accounts", spaceId, excludeOwnSharedCopies, forceRefresh)
        return accountsBySpace[spaceId] ?? []
    }

    func fetchTransactions(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinanceTransactionDTO] {
        try record("transactions", spaceId, excludeOwnSharedCopies, forceRefresh)
        return transactionsBySpace[spaceId] ?? []
    }

    func fetchPurchaseInbox(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinancePurchaseEvidenceInboxItemDTO] {
        try record("inbox", spaceId, excludeOwnSharedCopies, forceRefresh)
        return inboxBySpace[spaceId] ?? []
    }

    func fetchPurchases(
        spaceId: String,
        excludeOwnSharedCopies: Bool,
        forceRefresh: Bool
    ) async throws -> [FinancePurchaseRecordDTO] {
        try record("purchases", spaceId, excludeOwnSharedCopies, forceRefresh)
        return purchasesBySpace[spaceId] ?? []
    }

    func fetchPurchase(id: String, forceRefresh: Bool) async throws -> FinancePurchaseRecordDTO {
        guard let purchase = purchaseDetails[id] else { throw APIError.notFound }
        return purchase
    }

    private func record(
        _ kind: String,
        _ spaceId: String,
        _ excludeOwnSharedCopies: Bool,
        _ forceRefresh: Bool
    ) throws {
        requests.append(
            Request(
                kind: kind,
                spaceId: spaceId,
                excludeOwnSharedCopies: excludeOwnSharedCopies,
                forceRefresh: forceRefresh
            )
        )
        if failingSpaceIds.contains(spaceId) || failingKinds.contains(kind) {
            throw APIError.notFound
        }
    }
}

@MainActor
private final class FinanceBankConnectionStartMock: FinanceBankConnectionAPI {
    struct ConnectRequest: Equatable {
        let spaceId: String
        let connectionId: String?
    }

    let redirect: URL
    var connections: [FinanceBankConnectionDTO] = []
    var fetchRequests: [String] = []
    var connectRequests: [ConnectRequest] = []

    init(redirect: URL) {
        self.redirect = redirect
    }

    func fetchConnections(spaceId: String) async throws -> [FinanceBankConnectionDTO] {
        fetchRequests.append(spaceId)
        return connections
    }

    func startBankConnection(
        spaceId: String,
        connectionId: String?
    ) async throws -> URL {
        connectRequests.append(.init(spaceId: spaceId, connectionId: connectionId))
        return redirect
    }
}

@MainActor
private final class FinanceBankAuthenticatorMock: FinanceBankAuthenticating {
    let result: FinanceBankAuthenticationResult
    var openedURLs: [URL] = []
    var callbackSchemes: [String] = []

    init(result: FinanceBankAuthenticationResult) {
        self.result = result
    }

    func authenticate(
        at url: URL,
        callbackURLScheme: String
    ) async throws -> FinanceBankAuthenticationResult {
        openedURLs.append(url)
        callbackSchemes.append(callbackURLScheme)
        return result
    }
}

@MainActor
private final class FinanceBankConnectionCoordinatorMock: FinanceBankConnectionCoordinating {
    struct ConnectRequest: Equatable {
        let spaceId: String
        let connectionId: String?
    }

    var outcomes: [FinanceBankConnectionOutcome]
    var connectionsBySpace: [String: [FinanceBankConnectionDTO]] = [:]
    var fetchRequests: [String] = []
    var connectRequests: [ConnectRequest] = []

    init(outcomes: [FinanceBankConnectionOutcome] = []) {
        self.outcomes = outcomes
    }

    func fetchConnections(spaceId: String) async throws -> [FinanceBankConnectionDTO] {
        fetchRequests.append(spaceId)
        return connectionsBySpace[spaceId] ?? []
    }

    func connect(
        spaceId: String,
        connectionId: String?
    ) async -> FinanceBankConnectionOutcome {
        connectRequests.append(.init(spaceId: spaceId, connectionId: connectionId))
        return outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }
}

private final class FinanceBankRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    func append(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil,
           let stream = captured.httpBodyStream,
           let body = Self.read(stream) {
            captured.httpBody = body
        }
        lock.withLock { storage.append(captured) }
    }

    var requests: [URLRequest] {
        lock.withLock { storage }
    }

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
