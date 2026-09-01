import XCTest
@testable import HausKlar

final class ArtworkDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Contract decoding

    func testDecodesArtworkResponseContract() throws {
        let json = """
        {
          "id": "art-1",
          "child_id": "00000000-0000-0000-0000-000000000011",
          "child_name": "Child One",
          "title": "Rocket ship",
          "approx_date": "2026-07",
          "date_precision": "month",
          "age_label": "Age 4",
          "notes": "Painted at nursery",
          "created_at": "2026-07-12T10:00:00+00:00",
          "image_url": "/artworks/art-1/image"
        }
        """
        let artwork = try decoder.decode(ArtworkDTO.self, from: Data(json.utf8))

        XCTAssertEqual(artwork.id, "art-1")
        XCTAssertEqual(artwork.childName, "Child One")
        XCTAssertEqual(artwork.title, "Rocket ship")
        XCTAssertEqual(artwork.approxDate, "2026-07")
        XCTAssertEqual(artwork.datePrecision, "month")
        XCTAssertEqual(artwork.ageLabel, "Age 4")
        XCTAssertEqual(artwork.imageUrl, "/artworks/art-1/image")
        XCTAssertEqual(artwork.dateLabel, "July 2026")
    }

    func testDecodesNullOptionalFields() throws {
        let json = """
        {
          "id": "art-2",
          "child_id": "00000000-0000-0000-0000-000000000012",
          "child_name": "Child Two",
          "title": null,
          "approx_date": "2026",
          "date_precision": "year",
          "age_label": null,
          "notes": null,
          "created_at": "2026-07-12T10:00:00+00:00",
          "image_url": "/artworks/art-2/image"
        }
        """
        let artwork = try decoder.decode(ArtworkDTO.self, from: Data(json.utf8))

        XCTAssertNil(artwork.title)
        XCTAssertNil(artwork.ageLabel)
        XCTAssertNil(artwork.notes)
        XCTAssertEqual(artwork.dateLabel, "2026")
    }

    func testDecodesNullChildName() throws {
        // A soft-deleted child LEFT JOINs to null child_name; one null must not fail the decode.
        let json = """
        {
          "id": "art-3",
          "child_id": "00000000-0000-0000-0000-000000000013",
          "child_name": null,
          "title": "Scribbles",
          "approx_date": "2026",
          "date_precision": "year",
          "age_label": null,
          "notes": null,
          "created_at": "2026-07-12T10:00:00+00:00",
          "image_url": "/artworks/art-3/image"
        }
        """
        let artwork = try decoder.decode(ArtworkDTO.self, from: Data(json.utf8))

        XCTAssertNil(artwork.childName)
        XCTAssertEqual(artwork.childDisplayName, "Unknown")
    }

    // MARK: - Rough date parsing

    func testParsesYearPrecision() {
        let date = ApproxDate(string: "2026")
        XCTAssertEqual(date, ApproxDate(year: 2026))
        XCTAssertNil(date?.month)
        XCTAssertNil(date?.day)
        XCTAssertEqual(date?.precision, "year")
        XCTAssertEqual(date?.apiValue, "2026")
    }

    func testParsesMonthPrecision() {
        let date = ApproxDate(string: "2026-07")
        XCTAssertEqual(date?.year, 2026)
        XCTAssertEqual(date?.month, 7)
        XCTAssertNil(date?.day)
        XCTAssertEqual(date?.precision, "month")
        XCTAssertEqual(date?.apiValue, "2026-07")
    }

    func testParsesDayPrecision() {
        let date = ApproxDate(string: "2026-07-12")
        XCTAssertEqual(date?.year, 2026)
        XCTAssertEqual(date?.month, 7)
        XCTAssertEqual(date?.day, 12)
        XCTAssertEqual(date?.precision, "day")
        XCTAssertEqual(date?.apiValue, "2026-07-12")
    }

    func testRejectsMalformedStrings() {
        XCTAssertNil(ApproxDate(string: ""))
        XCTAssertNil(ApproxDate(string: "26"))
        XCTAssertNil(ApproxDate(string: "2026-13"))
        XCTAssertNil(ApproxDate(string: "2026-00"))
        XCTAssertNil(ApproxDate(string: "2026-7"))
        XCTAssertNil(ApproxDate(string: "2026-07-32"))
        XCTAssertNil(ApproxDate(string: "2026-07-12-05"))
        XCTAssertNil(ApproxDate(string: "not-a-date"))
    }

    func testApiValuePadsSingleDigits() {
        XCTAssertEqual(ApproxDate(year: 2026, month: 3).apiValue, "2026-03")
        XCTAssertEqual(ApproxDate(year: 2026, month: 3, day: 4).apiValue, "2026-03-04")
    }

    func testDayWithoutMonthIsDropped() {
        let date = ApproxDate(year: 2026, month: nil, day: 12)
        XCTAssertNil(date.day)
        XCTAssertEqual(date.precision, "year")
        XCTAssertEqual(date.apiValue, "2026")
    }

    func testDisplayLabels() {
        XCTAssertEqual(ApproxDate(year: 2026).displayLabel, "2026")
        XCTAssertEqual(ApproxDate(year: 2026, month: 7).displayLabel, "July 2026")
        XCTAssertEqual(ApproxDate(year: 2026, month: 7, day: 12).displayLabel, "12 July 2026")
    }

    // MARK: - Update request encoding

    func testUpdateRequestOmitsNilFields() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(
            ArtworkUpdateRequest(
                title: "New title",
                approxDate: "2026-07",
                childId: "child-1",
                notes: nil,
                medium: nil,
                story: nil,
                childQuote: nil,
                schoolYear: nil,
                favourite: false,
                includeInYearbook: false,
                yearbookPosition: nil
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["title"] as? String, "New title")
        XCTAssertEqual(object["approx_date"] as? String, "2026-07")
        XCTAssertEqual(object["child_id"] as? String, "child-1")
        XCTAssertNil(object["notes"])
    }
}
