import XCTest
@testable import HausKlar

final class RenewalDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    // MARK: - Contract decoding

    func testDecodesFullRenewalContract() throws {
        let json = """
        {
          "id": "ren-1",
          "title": "Car MOT",
          "category": "vehicle",
          "due_date": "2026-09-30",
          "days_until": 12,
          "status": "due_soon",
          "recurrence_months": 12,
          "cost_pence": 5499,
          "reminder_days_before": 21,
          "source_document_id": "doc-9",
          "source_document": {
            "id": "doc-9",
            "title": "MOT certificate",
            "original_filename": "mot.pdf",
            "media_type": "application/pdf",
            "file_size": 42000,
            "download_url": "/api/documents/doc-9/content"
          },
          "notes": "Kwik Fit Example Town",
          "created_at": "2026-07-12T10:00:00+00:00"
        }
        """
        let renewal = try decoder.decode(RenewalDTO.self, from: Data(json.utf8))

        XCTAssertEqual(renewal.id, "ren-1")
        XCTAssertEqual(renewal.title, "Car MOT")
        XCTAssertEqual(renewal.categoryValue, .vehicle)
        XCTAssertEqual(renewal.daysUntil, 12)
        XCTAssertEqual(renewal.status, .dueSoon)
        XCTAssertEqual(renewal.status.label, "Due soon")
        XCTAssertEqual(renewal.recurrenceMonths, 12)
        XCTAssertEqual(renewal.costPence, 5499)
        XCTAssertEqual(renewal.costDisplay, "£54.99")
        XCTAssertEqual(renewal.reminderDaysBefore, 21)
        XCTAssertEqual(renewal.sourceDocumentId, "doc-9")
        XCTAssertEqual(renewal.sourceDocument?.title, "MOT certificate")
        XCTAssertEqual(renewal.sourceDocument?.downloadUrl, "/api/documents/doc-9/content")
        XCTAssertEqual(renewal.dueLabel, "in 12 days")
        XCTAssertEqual(renewal.recurrenceLabel, "Renews yearly")
    }

    func testDecodesNullOptionalFields() throws {
        let json = """
        {
          "id": "ren-2",
          "title": "Passport",
          "category": "document",
          "due_date": "2027-01-01",
          "days_until": 200,
          "status": "upcoming",
          "recurrence_months": null,
          "cost_pence": null,
          "reminder_days_before": 30,
          "source_document_id": null,
          "notes": null,
          "created_at": "2026-07-12T10:00:00+00:00"
        }
        """
        let renewal = try decoder.decode(RenewalDTO.self, from: Data(json.utf8))

        XCTAssertNil(renewal.recurrenceMonths)
        XCTAssertNil(renewal.costPence)
        XCTAssertNil(renewal.costDisplay)
        XCTAssertNil(renewal.sourceDocumentId)
        XCTAssertNil(renewal.sourceDocument)
        XCTAssertNil(renewal.notes)
        XCTAssertNil(renewal.recurrenceLabel)
        XCTAssertEqual(renewal.status, .upcoming)
        XCTAssertEqual(renewal.categoryValue, .document)
    }

    func testUnknownCategoryFallsBackToOther() throws {
        let json = """
        {
          "id": "ren-3", "title": "Mystery", "category": "spaceship",
          "due_date": "2026-08-01", "days_until": -3, "status": "overdue",
          "recurrence_months": null, "cost_pence": null, "reminder_days_before": 21,
          "source_document_id": null, "notes": null, "created_at": "2026-07-12T10:00:00+00:00"
        }
        """
        let renewal = try decoder.decode(RenewalDTO.self, from: Data(json.utf8))

        XCTAssertEqual(renewal.categoryValue, .other)
        XCTAssertEqual(renewal.status, .overdue)
        XCTAssertEqual(renewal.dueLabel, "3 days overdue")
    }

    func testLibraryRenewalLinkIsLimitedToDueLoansAndTheOfficialCatalogue() throws {
        let json = """
        {
          "accounts": [],
          "loans": [
            {
              "id": "loan-1", "account_id": "account-1", "account_label": "Children",
              "title": "The Wild Robot", "author": "Peter Brown", "material_format": "Book",
              "due_date": "2026-08-18", "days_until": 7, "status": "due_soon",
              "provider_status": "Renewable", "renewable": true, "renewal_count": 0,
              "renew_url": "https://library.example.invalid/cgi-bin/spydus.exe/PGM/OPAC/CCOPT/LB/1?ISGLB=1"
            },
            {
              "id": "loan-2", "account_id": "account-1", "account_label": "Children",
              "title": "Matilda", "author": null, "material_format": null,
              "due_date": "2026-08-19", "days_until": 8, "status": "current",
              "provider_status": null, "renewable": null, "renewal_count": null,
              "renew_url": "https://library.example.invalid/cgi-bin/spydus.exe/PGM/OPAC/CCOPT/LB/1?ISGLB=1"
            },
            {
              "id": "loan-3", "account_id": "account-1", "account_label": "Children",
              "title": "Dog Man", "author": null, "material_format": null,
              "due_date": "2026-08-18", "days_until": 3, "status": "due_soon",
              "provider_status": null, "renewable": null, "renewal_count": null,
              "renew_url": "https://example.com/collect"
            }
          ]
        }
        """
        let overview = try decoder.decode(LibraryOverviewDTO.self, from: Data(json.utf8))

        XCTAssertEqual(overview.loans[0].renewalURL?.host, "library.example.invalid")
        XCTAssertNil(overview.loans[1].renewalURL)
        XCTAssertNil(overview.loans[2].renewalURL)
    }

    // MARK: - Due labels

    func testDueLabelBoundaries() throws {
        XCTAssertEqual(makeRenewal(daysUntil: 0).dueLabel, "Due today")
        XCTAssertEqual(makeRenewal(daysUntil: 1).dueLabel, "Due tomorrow")
        XCTAssertEqual(makeRenewal(daysUntil: -1).dueLabel, "1 day overdue")
        XCTAssertEqual(makeRenewal(daysUntil: 5).dueLabel, "in 5 days")
        XCTAssertEqual(makeRenewal(daysUntil: -5).dueLabel, "5 days overdue")
    }

    func testCostDisplayFormatsPence() throws {
        XCTAssertEqual(makeRenewal(costPence: 0).costDisplay, "£0.00")
        XCTAssertEqual(makeRenewal(costPence: 5).costDisplay, "£0.05")
        XCTAssertEqual(makeRenewal(costPence: 10000).costDisplay, "£100.00")
    }

    // MARK: - Request encoding

    func testUpdateRequestOmitsNilFields() throws {
        let data = try encoder.encode(
            RenewalUpdateRequest(
                title: "New title", category: nil, dueDate: "2026-10-01",
                recurrenceMonths: nil, costPence: nil, reminderDaysBefore: 14,
                sourceDocumentId: nil, provider: nil, reference: nil,
                actionUrl: nil, comparisonUrl: nil, contactUrl: nil, notes: nil,
                includeInHouseholdFinance: false, paymentHandling: "manual",
                showInCalendar: false, showInTasks: false, responsibleUserId: nil,
                remindersEnabled: false, escalateAfterDays: nil
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["title"] as? String, "New title")
        XCTAssertEqual(object["due_date"] as? String, "2026-10-01")
        XCTAssertEqual(object["reminder_days_before"] as? Int, 14)
        XCTAssertNil(object["category"])
        XCTAssertNil(object["cost_pence"])
        XCTAssertNil(object["recurrence_months"])
        XCTAssertNil(object["notes"])
    }

    func testCreateRequestEncodesSnakeCase() throws {
        let data = try encoder.encode(
            RenewalCreateRequest(
                title: "TV Licence", category: "utility", dueDate: "2026-12-01",
                recurrenceMonths: 12, costPence: 15900, reminderDaysBefore: 21,
                sourceDocumentId: nil, provider: nil, reference: nil,
                actionUrl: nil, comparisonUrl: nil, contactUrl: nil, notes: nil,
                includeInHouseholdFinance: false, paymentHandling: "manual",
                showInCalendar: false, showInTasks: false, responsibleUserId: nil,
                remindersEnabled: false, escalateAfterDays: nil, checklist: []
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["title"] as? String, "TV Licence")
        XCTAssertEqual(object["category"] as? String, "utility")
        XCTAssertEqual(object["due_date"] as? String, "2026-12-01")
        XCTAssertEqual(object["recurrence_months"] as? Int, 12)
        XCTAssertEqual(object["cost_pence"] as? Int, 15900)
        XCTAssertEqual(object["reminder_days_before"] as? Int, 21)
        XCTAssertNil(object["notes"])
    }

    // MARK: - Helpers

    private func makeRenewal(daysUntil: Int = 10, costPence: Int? = nil) -> RenewalDTO {
        RenewalDTO(
            id: "x", title: "x", category: "other", dueDate: "2026-07-22",
            daysUntil: daysUntil, status: .upcoming, recurrenceMonths: nil,
            costPence: costPence, reminderDaysBefore: 21, sourceDocumentId: nil,
            notes: nil, createdAt: "2026-07-12T10:00:00+00:00"
        )
    }
}
