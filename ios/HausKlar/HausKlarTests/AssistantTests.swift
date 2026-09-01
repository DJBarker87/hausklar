import XCTest
@testable import HausKlar

@MainActor
final class AssistantTests: XCTestCase {
    func testAIConsentStatusDecodesExplicitProviderDisclosure() throws {
        let json = """
        {
          "consented": true,
          "version": "2026-07-13",
          "consented_at": "2026-07-13T10:00:00Z",
          "provider": "OpenAI",
          "disclosure": "Only user-requested AI processing is allowed.",
          "background_processing": false
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let status = try decoder.decode(AIConsentStatusDTO.self, from: Data(json.utf8))

        XCTAssertTrue(status.consented)
        XCTAssertEqual(status.provider, "OpenAI")
        XCTAssertFalse(status.backgroundProcessing)
        XCTAssertEqual(status.version, "2026-07-13")
    }

    func testAssistantResponseDecodesPendingCalendarAction() throws {
        let json = """
        {
          "answer": "I have prepared football for confirmation.",
          "actions": [{
            "id": "action-1",
            "kind": "calendar_event",
            "summary": "Add 'Football' on Tuesday 14 July 2026 at 5pm",
            "status": "pending",
            "expires_at": "2026-07-10T12:30:00Z"
          }],
          "processor": "bismarck"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(AssistantMessageResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.processor, "bismarck")
        XCTAssertEqual(response.actions.first?.kind, .calendarEvent)
        XCTAssertEqual(response.actions.first?.status, .pending)
    }

    func testAssistantActionStateCanRepresentExecutionResult() throws {
        let json = """
        {
          "id": "action-1",
          "kind": "home_lights",
          "summary": "Turn off all Home Assistant lights",
          "status": "pending",
          "expires_at": "2026-07-10T12:30:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dto = try decoder.decode(AssistantActionDTO.self, from: Data(json.utf8))
        var state = AssistantActionState(dto)

        state.status = .executed
        state.resultMessage = "All lights were turned off."

        XCTAssertEqual(state.kind, .homeLights)
        XCTAssertEqual(state.status, .executed)
        XCTAssertEqual(state.resultMessage, "All lights were turned off.")
    }

    func testMessageRequestUsesSnakeCaseAndIncludesConversationContext() throws {
        let request = AssistantMessageRequestDTO(
            message: "Every Tuesday",
            history: [
                AssistantHistoryDTO(role: .user, content: "Add weekly football at 5pm"),
                AssistantHistoryDTO(role: .assistant, content: "Which day?"),
            ],
            clientNow: "2026-07-10T12:00:00Z",
            timezone: "Europe/London"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["client_now"] as? String, "2026-07-10T12:00:00Z")
        XCTAssertEqual(object["timezone"] as? String, "Europe/London")
        XCTAssertEqual((object["history"] as? [[String: Any]])?.count, 2)
    }

    func testChatViewModelRequiresNonBlankInput() {
        let viewModel = AssistantChatViewModel()

        viewModel.inputText = "   "
        XCTAssertFalse(viewModel.canSend)
        viewModel.inputText = "What is on today?"
        XCTAssertTrue(viewModel.canSend)
        XCTAssertTrue(viewModel.suggestedPrompts.contains { $0.contains("shopping") })
    }

    func testAssistantReviewButtonsDescribeTheActualChange() {
        XCTAssertEqual(AssistantActionKind.calendarEvent.reviewActionTitle, "Create event")
        XCTAssertEqual(AssistantActionKind.calendarEvent.confirmationTitle, "Create event")
        XCTAssertEqual(AssistantActionKind.shoppingItem.reviewActionTitle, "Add to shopping")
        XCTAssertEqual(AssistantActionKind.shoppingItem.confirmationTitle, "Add item")
        XCTAssertEqual(AssistantActionKind.completeTask.confirmationTitle, "Complete")
        XCTAssertEqual(AssistantChatViewModel().thinkingStatus, "Thinking…")
    }

    func testFitnessCoachHandoffReturnsExactUnsentDraftWithoutClearingOrSending() {
        let viewModel=AssistantChatViewModel()
        let exact="  Help me plan tomorrow\nusing the family Calendar  "
        viewModel.inputText=exact

        XCTAssertEqual(viewModel.fitnessCoachDraftForHandoff(),exact)
        XCTAssertEqual(viewModel.inputText,exact)
        XCTAssertTrue(viewModel.messages.isEmpty)

        viewModel.isSending=true
        XCTAssertNil(viewModel.fitnessCoachDraftForHandoff())
        viewModel.isSending=false
        viewModel.inputText=" \n "
        XCTAssertNil(viewModel.fitnessCoachDraftForHandoff())
    }

    func testOnlyOneResolutionCanStartForAnAction() {
        let viewModel = AssistantChatViewModel()
        let messageID = UUID()
        let action = AssistantActionState(
            AssistantActionDTO(
                id: "action-1",
                kind: .createTask,
                summary: "Create task",
                status: .pending,
                expiresAt: "2026-07-10T12:30:00Z"
            )
        )
        viewModel.messages = [
            AssistantChatMessage(
                id: messageID,
                role: .assistant,
                content: "Ready.",
                actions: [action]
            )
        ]

        XCTAssertNotNil(viewModel.beginResolution(actionID: action.id, messageID: messageID))
        XCTAssertNil(viewModel.beginResolution(actionID: action.id, messageID: messageID))
    }

    func testEditableCalendarPreviewDecodesWithoutBreakingLegacyActions() throws {
        let json = """
        {
          "id": "action-2",
          "kind": "calendar_event",
          "summary": "Add swimming",
          "status": "pending",
          "expires_at": "2026-07-13T10:30:00Z",
          "editable": true,
          "preview": {
            "kind": "calendar_event",
            "title": "Swimming",
            "description": "Bring goggles",
            "start_time": "2026-07-16T16:00:00Z",
            "end_time": "2026-07-16T17:00:00Z",
            "all_day": false,
            "recurrence_rule": null,
            "assigned_to": "child-1",
            "term_time_only": false
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let action = try decoder.decode(AssistantActionDTO.self, from: Data(json.utf8))
        XCTAssertTrue(action.editable)
        guard case .calendar(let preview) = action.preview else {
            return XCTFail("Expected a calendar preview")
        }
        XCTAssertEqual(preview.title, "Swimming")
        XCTAssertEqual(preview.assignedTo, "child-1")

        let legacyJSON = """
        {"id":"old","kind":"complete_task","summary":"Complete it","status":"pending","expires_at":"2026-07-13T10:30:00Z"}
        """
        let legacy = try decoder.decode(AssistantActionDTO.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(legacy.editable)
        XCTAssertNil(legacy.preview)
    }

    func testMalformedAssistantPreviewFailsClosed() throws {
        let json = """
        {
          "id": "action-malformed",
          "kind": "calendar_event",
          "summary": "Add swimming",
          "status": "pending",
          "expires_at": "2026-07-13T10:30:00Z",
          "editable": true,
          "preview": {
            "kind": "calendar_event",
            "title": 42
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        XCTAssertThrowsError(
            try decoder.decode(AssistantActionDTO.self, from: Data(json.utf8))
        )
    }

    func testStrictShoppingPatchEncodesOnlyShoppingFields() throws {
        let request = AssistantActionUpdateRequest(
            preview: .shopping(
                ShoppingActionPreview(
                    kind: .shoppingItem,
                    name: "Milk",
                    quantity: "2 pints",
                    category: "Dairy"
                )
            )
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["kind"] as? String, "shopping_item")
        XCTAssertEqual(object["name"] as? String, "Milk")
        XCTAssertEqual(object["quantity"] as? String, "2 pints")
        XCTAssertNil(object["title"])
        XCTAssertNil(object["due_date"])

        let clearRequest = AssistantActionUpdateRequest(
            preview: .shopping(
                ShoppingActionPreview(kind: .shoppingItem, name: "Milk", quantity: nil, category: nil)
            )
        )
        let clearObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(clearRequest)) as? [String: Any]
        )
        XCTAssertTrue(clearObject["quantity"] is NSNull)
        XCTAssertTrue(clearObject["category"] is NSNull)
    }

    func testAddHubUsesSharedStableOptionOrder() {
        XCTAssertEqual(
            AddHubDestination.allCases,
            [.event, .task, .shopping, .medicine, .nap, .document, .several]
        )
    }

    func testCompletedShoppingSelectionKeepsUncheckedItemsOutOfClearRequest() {
        let items = [
            ShoppingItemDTO(id: "checked", name: "Milk", quantity: nil, category: nil, checked: true),
            ShoppingItemDTO(id: "keep", name: "Bread", quantity: nil, category: nil, checked: false),
            ShoppingItemDTO(id: "checked-2", name: "Apples", quantity: nil, category: nil, checked: true),
        ]

        XCTAssertEqual(ShoppingListViewModel.completedItemIDs(in: items), ["checked", "checked-2"])
    }

    func testRecurrenceChoicesAreUnderstandableAndPreserveWeeklyDetail() {
        let weekly = "FREQ=WEEKLY;BYDAY=TH"
        XCTAssertEqual(AssistantRecurrenceOption(rule: weekly), .weekly)
        XCTAssertEqual(AssistantRecurrenceOption.weekly.rule(preserving: weekly), weekly)
        XCTAssertEqual(AssistantRecurrenceOption.monthly.rule(preserving: weekly), "FREQ=MONTHLY")
        XCTAssertNil(AssistantRecurrenceOption.never.rule(preserving: weekly))
        XCTAssertEqual(AssistantRecurrenceOption.weekly.title, "Every week")
    }

    func testFailedAssistantSendRestoresComposerAndReusesBubbleForRetry() {
        let viewModel = AssistantChatViewModel()
        let text = "Add milk to shopping"
        viewModel.messages = [AssistantChatMessage(role: .user, content: text)]

        viewModel.recordSendFailure(text, message: "Connection lost")

        XCTAssertEqual(viewModel.inputText, text)
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertTrue(viewModel.canRetry)
        XCTAssertTrue(viewModel.shouldReuseFailedBubble(for: text))

        viewModel.clear()
        XCTAssertFalse(viewModel.canRetry)
    }
}
