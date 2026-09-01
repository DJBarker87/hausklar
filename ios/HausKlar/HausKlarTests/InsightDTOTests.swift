import XCTest
@testable import HausKlar

final class InsightDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testDecodesInsightsContract() throws {
        let json = """
        [
          {
            "id": "i1",
            "kind": "missing_event",
            "message": "Sports day is mentioned in a letter but not on the calendar.",
            "detail": "Found in 'Summer term newsletter'",
            "target_date": "2026-07-18",
            "source_document_id": "d1",
            "created_at": "2026-07-12T06:00:00+00:00",
            "suggested_task_title": "Pack swim kit and towels"
          },
          {
            "id": "i2",
            "kind": "weather",
            "message": "Rain expected during school pickup.",
            "detail": null,
            "target_date": null,
            "source_document_id": null,
            "created_at": "2026-07-12T06:00:00+00:00"
          }
        ]
        """
        let insights = try decoder.decode([InsightDTO].self, from: Data(json.utf8))

        XCTAssertEqual(insights.count, 2)
        XCTAssertEqual(insights[0].id, "i1")
        XCTAssertEqual(insights[0].kind, "missing_event")
        XCTAssertEqual(insights[0].detail, "Found in 'Summer term newsletter'")
        XCTAssertEqual(insights[0].targetDate, "2026-07-18")
        XCTAssertEqual(insights[0].sourceDocumentId, "d1")
        XCTAssertEqual(insights[0].suggestedTaskTitle, "Pack swim kit and towels")
        XCTAssertNil(insights[1].detail)
        XCTAssertNil(insights[1].targetDate)
        XCTAssertNil(insights[1].sourceDocumentId)
    }

    func testDecodesEmptyList() throws {
        let insights = try decoder.decode([InsightDTO].self, from: Data("[]".utf8))
        XCTAssertTrue(insights.isEmpty)
    }

    func testIconNamesPerKindWithUnknownFallback() {
        func insight(_ kind: String) -> InsightDTO {
            InsightDTO(
                id: "i", kind: kind, message: "m", detail: nil,
                targetDate: nil, sourceDocumentId: nil, createdAt: "2026-07-12T06:00:00+00:00",
                suggestedTaskTitle: nil
            )
        }
        XCTAssertEqual(insight("missing_event").iconName, "calendar.badge.exclamationmark")
        XCTAssertEqual(insight("prep").iconName, "backpack")
        XCTAssertEqual(insight("weather").iconName, "cloud.rain")
        XCTAssertEqual(insight("conflict").iconName, "exclamationmark.triangle")
        XCTAssertEqual(insight("other").iconName, "exclamationmark.triangle")
        XCTAssertEqual(insight("something_new").iconName, "exclamationmark.triangle")
    }

    func testDecodesDismissResponse() throws {
        let response = try decoder.decode(
            InsightDismissResponseDTO.self, from: Data(#"{"status": "dismissed"}"#.utf8)
        )
        XCTAssertEqual(response.status, "dismissed")
    }

    func testDecodesPreparationPackSuggestion() throws {
        let json = #"{"id":"p:e:o","template_id":"p","template_name":"Swimming","event_id":"e","event_title":"Swimming","event_all_day":false,"event_start":"2026-07-12T10:00:00+01:00","occurrence_start":"2026-07-12T09:00:00+00:00","items":["Pack swim kit","Pack towels"],"lead_hours":24,"assigned_to":null}"#
        let suggestion = try decoder.decode(PrepPackSuggestionDTO.self, from: Data(json.utf8))
        XCTAssertEqual(suggestion.templateName, "Swimming")
        XCTAssertEqual(suggestion.items, ["Pack swim kit", "Pack towels"])
        XCTAssertFalse(suggestion.eventAllDay)
    }
}
