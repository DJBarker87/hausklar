import XCTest
@testable import HausKlar

final class YearbookDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Full contract

    func testDecodesFullYearbookContract() throws {
        let json = """
        {
          "child": {"id": "00000000-0000-0000-0000-000000000012", "name": "Child Two", "age": 4},
          "year": 2025,
          "narrative": "What a year of growing and drawing.",
          "sections": {
            "artwork": {"count": 12, "items": [
              {"id": "art-1", "title": "A rocket", "approx_date": "2025-03", "image_url": "/artworks/art-1/image"}
            ]},
            "growth": {
              "start": {"date": "2025-01-10", "height_cm": 80.0, "weight_kg": 10.0},
              "end": {"date": "2025-11-10", "height_cm": 88.0, "weight_kg": 12.5},
              "grew_cm": 8.0, "gained_kg": 2.5, "measurements": 4
            },
            "star_charts": {"completed": 3, "earned_pence": 1500, "titles": ["Potty training", "Big boy bed"]},
            "learning": {"reading_sessions": 40, "minutes_read": 600, "books": ["The Gruffalo"], "book_count": 8, "spelling_tests": 2},
            "illnesses": {"count": 2, "items": [{"started_at": "2025-02-01T09:00:00+00:00", "notes": "Chickenpox"}]},
            "adventures": {"count": 15, "items": [{"title": "Swimming gala", "start_time": "2025-06-01T09:00:00+00:00", "location": "Example Town"}]},
            "favourite_meals": ["Spaghetti bolognese"],
            "photos": {"count": 320, "highlights": [{"asset_id": "photo-1", "thumbnail_url": "/photos/photo-1/thumbnail?size=preview"}]}
          }
        }
        """
        let book = try decoder.decode(YearbookDTO.self, from: Data(json.utf8))

        XCTAssertEqual(book.child.name, "Child Two")
        XCTAssertEqual(book.child.age, 4)
        XCTAssertEqual(book.year, 2025)
        XCTAssertEqual(book.narrative, "What a year of growing and drawing.")

        XCTAssertEqual(book.sections.artwork.count, 12)
        XCTAssertEqual(book.sections.artwork.items.first?.title, "A rocket")
        XCTAssertEqual(book.sections.artwork.items.first?.imageUrl, "/artworks/art-1/image")
        XCTAssertEqual(book.sections.artwork.items.first?.dateLabel, "March 2025")

        XCTAssertEqual(book.sections.growth?.grewCm, 8.0)
        XCTAssertEqual(book.sections.growth?.gainedKg, 2.5)
        XCTAssertEqual(book.sections.growth?.measurements, 4)
        XCTAssertEqual(book.sections.growth?.start.heightCm, 80.0)
        XCTAssertEqual(book.sections.growth?.end.weightKg, 12.5)

        XCTAssertEqual(book.sections.starCharts.completed, 3)
        XCTAssertEqual(book.sections.starCharts.earnedPence, 1500)
        XCTAssertEqual(book.sections.starCharts.earnedDisplay, "£15.00")
        XCTAssertEqual(book.sections.starCharts.titles.count, 2)

        XCTAssertEqual(book.sections.learning.readingSessions, 40)
        XCTAssertEqual(book.sections.learning.minutesRead, 600)
        XCTAssertEqual(book.sections.learning.bookCount, 8)
        XCTAssertEqual(book.sections.learning.spellingTests, 2)

        XCTAssertEqual(book.sections.illnesses.count, 2)
        XCTAssertEqual(book.sections.illnesses.items.first?.notes, "Chickenpox")

        XCTAssertEqual(book.sections.adventures.count, 15)
        XCTAssertEqual(book.sections.adventures.items.first?.title, "Swimming gala")
        XCTAssertEqual(book.sections.adventures.items.first?.location, "Example Town")

        XCTAssertEqual(book.sections.favouriteMeals, ["Spaghetti bolognese"])

        XCTAssertEqual(book.sections.photos.count, 320)
        XCTAssertEqual(book.sections.photos.highlights.first?.assetId, "photo-1")
        XCTAssertEqual(book.sections.photos.highlights.first?.thumbnailUrl, "/photos/photo-1/thumbnail?size=preview")
        XCTAssertEqual(book.sections.photos.highlights.first?.id, "photo-1")

        XCTAssertFalse(book.isQuiet)
    }

    // MARK: - Nullable / sparse fields

    func testDecodesNullNarrativeAndGrowthAndNullableItemFields() throws {
        // narrative null, growth null, item titles/notes/location null, measurements null.
        let json = """
        {
          "child": {"id": "child-1", "name": "Child One", "age": 6},
          "year": 2024,
          "narrative": null,
          "sections": {
            "artwork": {"count": 1, "items": [
              {"id": "art-9", "title": null, "approx_date": "2024", "image_url": "/artworks/art-9/image"}
            ]},
            "growth": null,
            "star_charts": {"completed": 0, "earned_pence": 0, "titles": []},
            "learning": {"reading_sessions": 0, "minutes_read": 0, "books": [], "book_count": 0, "spelling_tests": 0},
            "illnesses": {"count": 1, "items": [{"started_at": "2024-02-01T09:00:00+00:00", "notes": null}]},
            "adventures": {"count": 1, "items": [{"title": "A walk", "start_time": "2024-06-01T09:00:00+00:00", "location": null}]},
            "favourite_meals": [],
            "photos": {"count": 0, "highlights": []}
          }
        }
        """
        let book = try decoder.decode(YearbookDTO.self, from: Data(json.utf8))

        XCTAssertNil(book.narrative)
        XCTAssertNil(book.sections.growth)
        XCTAssertNil(book.sections.artwork.items.first?.title)
        XCTAssertEqual(book.sections.artwork.items.first?.dateLabel, "2024")
        XCTAssertNil(book.sections.illnesses.items.first?.notes)
        XCTAssertNil(book.sections.adventures.items.first?.location)
        XCTAssertTrue(book.sections.photos.highlights.isEmpty)
        XCTAssertFalse(book.isQuiet) // has artwork, an adventure and an illness
    }

    func testDecodesEmptyGrowthPointMeasurements() throws {
        // Growth present but the endpoints carry null heights/weights (measurement notes only).
        let json = """
        {
          "start": {"date": "2025-01-01", "height_cm": null, "weight_kg": null},
          "end": {"date": "2025-12-01", "height_cm": null, "weight_kg": null},
          "grew_cm": null, "gained_kg": null, "measurements": 2
        }
        """
        let growth = try decoder.decode(YearbookDTO.Growth.self, from: Data(json.utf8))

        XCTAssertNil(growth.grewCm)
        XCTAssertNil(growth.gainedKg)
        XCTAssertNil(growth.start.heightCm)
        XCTAssertEqual(growth.measurements, 2)
    }

    func testQuietYearIsDetected() throws {
        let json = """
        {
          "child": {"id": "child-1", "name": "Child One", "age": 6},
          "year": 2023,
          "narrative": null,
          "sections": {
            "artwork": {"count": 0, "items": []},
            "growth": null,
            "star_charts": {"completed": 0, "earned_pence": 0, "titles": []},
            "learning": {"reading_sessions": 0, "minutes_read": 0, "books": [], "book_count": 0, "spelling_tests": 0},
            "illnesses": {"count": 0, "items": []},
            "adventures": {"count": 0, "items": []},
            "favourite_meals": [],
            "photos": {"count": 0, "highlights": []}
          }
        }
        """
        let book = try decoder.decode(YearbookDTO.self, from: Data(json.utf8))

        XCTAssertTrue(book.isQuiet)
    }

    // MARK: - Years endpoint

    func testDecodesYearsResponse() throws {
        let json = #"{"years": [2026, 2025, 2024]}"#
        let response = try decoder.decode(YearbookYearsDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.years, [2026, 2025, 2024])
    }

    func testDecodesChooseAndArrangeOptions() throws {
        let json = """
        {
          "child": {"id": "child-1", "name": "Child One"},
          "year": 2026,
          "artwork": [{
            "id": "art-1", "title": "Rocket", "approx_date": "2026-03",
            "include_in_yearbook": true, "yearbook_position": 1,
            "image_url": "/artworks/art-1/image?v=2"
          }],
          "photos": [{
            "id": "photo-1", "caption": "Beach", "taken_on": "2026-07-12",
            "location": "Dorset", "include_in_yearbook": false,
            "yearbook_position": null,
            "image_url": "/child-photos/photo-1/image?size=thumb&v=2"
          }]
        }
        """
        let options = try decoder.decode(YearbookOptionsDTO.self, from: Data(json.utf8))

        XCTAssertEqual(options.child.name, "Child One")
        XCTAssertEqual(options.artwork.first?.yearbookPosition, 1)
        XCTAssertTrue(options.artwork.first?.includeInYearbook == true)
        XCTAssertEqual(options.photos.first?.location, "Dorset")
        XCTAssertFalse(options.photos.first?.includeInYearbook == true)
    }

    func testArrangementRequestKeepsExactOrder() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(
            YearbookArrangementRequest(
                artworkIds: ["art-2", "art-1"],
                photoIds: ["photo-3", "photo-1"]
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["artwork_ids"] as? [String], ["art-2", "art-1"])
        XCTAssertEqual(object["photo_ids"] as? [String], ["photo-3", "photo-1"])
    }
}
