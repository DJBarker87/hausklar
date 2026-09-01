import XCTest
@testable import HausKlar

@MainActor
final class UniversalCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CaptureSessionDraftStore.resetForTests()
    }

    override func tearDown() {
        CaptureSessionDraftStore.resetForTests()
        super.tearDown()
    }

    func testCaptureResponseDecodesReviewableProposal() throws {
        let json = """
        {
          "proposals": [{
            "id": "proposal-1",
            "kind": "event",
            "title": "Sports day",
            "details": null,
            "start_time": "2026-07-17",
            "end_time": null,
            "due_date": null,
            "all_day": true,
            "assigned_to": "child-1",
            "assigned_to_name": "Alex",
            "confidence": 0.92,
            "source_text": "Sports day next Friday"
          }],
          "processor": "hermes",
          "warning": null
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(UniversalCaptureResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.processor, "hermes")
        XCTAssertEqual(response.proposals.first?.kind, .event)
        XCTAssertEqual(response.proposals.first?.assignedToName, "Alex")
    }

    func testAllDayEventRequestUsesAPIDateFormat() {
        let dto = UniversalCaptureProposalDTO(
            id: "proposal-1",
            kind: .event,
            title: "Sports day",
            details: nil,
            startTime: "2026-07-17",
            endTime: nil,
            dueDate: nil,
            allDay: true,
            assignedTo: "child-1",
            assignedToName: "Alex",
            confidence: 0.8,
            sourceText: nil
        )

        let request = EditableCaptureProposal(dto: dto).eventRequest()

        XCTAssertEqual(request.startTime, "2026-07-17")
        XCTAssertNil(request.endTime)
        XCTAssertTrue(request.allDay)
        XCTAssertEqual(request.assignedTo, "child-1")
    }

    func testTaskRequestPreservesAssignmentAndDueDate() throws {
        let dto = UniversalCaptureProposalDTO(
            id: "proposal-2",
            kind: .task,
            title: "Pay nursery",
            details: "Invoice in Documents",
            startTime: nil,
            endTime: nil,
            dueDate: "2026-07-18T16:00:00Z",
            allDay: true,
            assignedTo: "user-1",
            assignedToName: "Alex",
            confidence: 0.9,
            sourceText: nil
        )
        let member = FamilyMemberDTO(id: "user-1", name: "Alex", memberType: "user")

        let request = EditableCaptureProposal(dto: dto).taskRequest(member: member)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let assignees = try XCTUnwrap(object["assignees"] as? [[String: Any]])

        XCTAssertEqual(object["title"] as? String, "Pay nursery")
        XCTAssertNotNil(object["due_date"])
        XCTAssertEqual(assignees.first?["assignee_id"] as? String, "user-1")
        XCTAssertEqual(assignees.first?["assignee_type"] as? String, "user")
    }

    func testManualProposalStartsIncludedButRequiresTitle() {
        let proposal = EditableCaptureProposal(kind: .task)

        XCTAssertTrue(proposal.isIncluded)
        XCTAssertTrue(proposal.trimmedTitle.isEmpty)
        XCTAssertFalse(proposal.hasDueDate)
    }

    func testObviousShoppingSentenceBecomesDeterministicReviewItems() throws {
        let proposals = try XCTUnwrap(
            CaptureViewModel.simpleShoppingProposals(
                from: "Add milk and nappies to the shopping list."
            )
        )

        XCTAssertEqual(proposals.map(\.kind), [.shopping, .shopping])
        XCTAssertEqual(proposals.map(\.title), ["Milk", "Nappies"])
        XCTAssertTrue(proposals.allSatisfy(\.isIncluded))
    }

    func testBismarckIsSuggestedOnlyWhenDraftNeedsReasoning() {
        let clear = UniversalCaptureResponseDTO(
            proposals: [
                UniversalCaptureProposalDTO(
                    id: "clear",
                    kind: .task,
                    title: "Return nursery form",
                    details: nil,
                    startTime: nil,
                    endTime: nil,
                    dueDate: nil,
                    allDay: false,
                    assignedTo: nil,
                    assignedToName: nil,
                    confidence: 0.8,
                    sourceText: nil
                )
            ],
            processor: "deterministic",
            warning: nil
        )
        let unclear = UniversalCaptureResponseDTO(
            proposals: [
                UniversalCaptureProposalDTO(
                    id: "unclear",
                    kind: .task,
                    title: "Sort this out",
                    details: nil,
                    startTime: nil,
                    endTime: nil,
                    dueDate: nil,
                    allDay: false,
                    assignedTo: nil,
                    assignedToName: nil,
                    confidence: 0.48,
                    sourceText: nil
                )
            ],
            processor: "deterministic",
            warning: nil
        )

        XCTAssertFalse(CaptureViewModel.shouldSuggestBismarck(text: "Return nursery form", response: clear))
        XCTAssertTrue(CaptureViewModel.shouldSuggestBismarck(text: "Can you sort this out?", response: unclear))
        XCTAssertTrue(
            CaptureViewModel.shouldSuggestBismarck(
                text: "Return the form and then move swimming",
                response: clear
            )
        )
    }

    func testUnfinishedReviewSurvivesSheetRecreationForSameUserOnly() {
        let first = makeViewModel()
        first.prepare(ownerID: "dom", initialText: "")
        first.inputText = "Return the nursery form"
        first.startDirect(.task)
        first.proposals[0].title = "Return nursery form"
        first.persistDraft()

        let reopened = makeViewModel()
        reopened.prepare(ownerID: "dom", initialText: "")

        XCTAssertEqual(reopened.stage, .review)
        XCTAssertEqual(reopened.inputText, "Return the nursery form")
        XCTAssertEqual(reopened.proposals.first?.title, "Return nursery form")

        let otherUser = makeViewModel()
        otherUser.prepare(ownerID: "kat", initialText: "")

        XCTAssertEqual(otherUser.stage, .input)
        XCTAssertTrue(otherUser.inputText.isEmpty)
        XCTAssertTrue(otherUser.proposals.isEmpty)
    }

    func testBatchConfirmationKeepsPerItemSuccessAndFailure() async {
        var milk = EditableCaptureProposal(kind: .shopping)
        milk.title = "Milk"
        var form = EditableCaptureProposal(kind: .task)
        form.title = "Return nursery form"
        let emptyResponse = Self.emptyResponse

        let viewModel = CaptureViewModel(
            parser: { _, _ in emptyResponse },
            membersLoader: { [] },
            saver: { proposal, _ in
                guard proposal.kind == .shopping else { throw TestFailure.save }
                return CaptureSaveReceipt(resultId: "shopping-milk", kind: .shopping)
            }
        )
        viewModel.prepare(ownerID: "dom", initialText: "")
        viewModel.proposals = [milk, form]
        viewModel.stage = .review

        await viewModel.confirm()

        XCTAssertEqual(viewModel.stage, .review)
        XCTAssertEqual(viewModel.savedCount, 1)
        XCTAssertEqual(viewModel.includedCount, 1)
        XCTAssertEqual(viewModel.result(for: milk.id)?.state, .succeeded)
        XCTAssertEqual(viewModel.result(for: milk.id)?.resultId, "shopping-milk")
        XCTAssertEqual(viewModel.result(for: form.id)?.state, .failed)
        XCTAssertEqual(viewModel.errorMessage, "One item still needs attention.")
    }

    func testMemberLoadFailureIsVisibleWithoutInventingMembers() async {
        let emptyResponse = Self.emptyResponse
        let viewModel = CaptureViewModel(
            parser: { _, _ in emptyResponse },
            membersLoader: { throw TestFailure.load },
            saver: { proposal, _ in
                CaptureSaveReceipt(resultId: proposal.operationId, kind: proposal.kind)
            }
        )

        await viewModel.loadMembers()

        XCTAssertTrue(viewModel.familyMembers.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "Family members could not be loaded.")
    }

    func testShoppingRequestUsesStableRecordIDAndClientIdentity() throws {
        var proposal = EditableCaptureProposal(kind: .shopping)
        proposal.title = "  Milk  "
        proposal.quantity = " 2 pints "
        proposal.category = " Dairy "

        let request = proposal.shoppingRequest(
            clientId: "device-client",
            now: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(request.id, proposal.operationId)
        XCTAssertEqual(request.name, "Milk")
        XCTAssertEqual(request.quantity, "2 pints")
        XCTAssertEqual(request.category, "Dairy")
        XCTAssertEqual(request.clientId, "device-client")
    }

    private enum TestFailure: Error {
        case load
        case save
    }

    private static let emptyResponse = UniversalCaptureResponseDTO(
        proposals: [],
        processor: "deterministic",
        warning: nil
    )

    private func makeViewModel() -> CaptureViewModel {
        let emptyResponse = Self.emptyResponse
        return CaptureViewModel(
            parser: { _, _ in emptyResponse },
            membersLoader: { [] },
            saver: { proposal, _ in
                CaptureSaveReceipt(resultId: proposal.operationId, kind: proposal.kind)
            }
        )
    }
}
