import XCTest
@testable import HausKlar

final class ChildPhotoDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Contract decoding

    func testDecodesChildPhotoContract() throws {
        let json = """
        {
          "id": "photo-1",
          "child_id": "00000000-0000-0000-0000-000000000011",
          "child_name": "Child One",
          "caption": "First day at nursery",
          "taken_on": "2026-07-12",
          "location": "Example Town",
          "story": "Would not let go of the red bucket",
          "favourite": true,
          "include_in_yearbook": false,
          "yearbook_position": 4,
          "original_available": true,
          "created_at": "2026-07-12T10:00:00+00:00",
          "updated_at": "2026-07-12T11:00:00+00:00",
          "image_url": "/child-photos/photo-1/image?v=1",
          "original_image_url": "/child-photos/photo-1/image?size=original"
        }
        """
        let photo = try decoder.decode(ChildPhotoDTO.self, from: Data(json.utf8))

        XCTAssertEqual(photo.id, "photo-1")
        XCTAssertEqual(photo.childId, "00000000-0000-0000-0000-000000000011")
        XCTAssertEqual(photo.childName, "Child One")
        XCTAssertEqual(photo.caption, "First day at nursery")
        XCTAssertEqual(photo.takenOn, "2026-07-12")
        XCTAssertEqual(photo.location, "Example Town")
        XCTAssertEqual(photo.story, "Would not let go of the red bucket")
        XCTAssertTrue(photo.favourite == true)
        XCTAssertFalse(photo.includeInYearbook == true)
        XCTAssertEqual(photo.yearbookPosition, 4)
        XCTAssertTrue(photo.originalAvailable == true)
        XCTAssertEqual(photo.imageUrl, "/child-photos/photo-1/image?v=1")
        XCTAssertEqual(photo.originalImageUrl, "/child-photos/photo-1/image?size=original")
        XCTAssertEqual(photo.childDisplayName, "Child One")
        XCTAssertEqual(photo.takenOnLabel, "12 July 2026")
    }

    func testDecodesNullOptionalFields() throws {
        // caption is nullable; a bare capture with no caption must still decode.
        let json = """
        {
          "id": "photo-2",
          "child_id": "00000000-0000-0000-0000-000000000012",
          "child_name": "Child Two",
          "caption": null,
          "taken_on": "2026-01-03",
          "created_at": "2026-07-12T10:00:00+00:00",
          "image_url": "/child-photos/photo-2/image"
        }
        """
        let photo = try decoder.decode(ChildPhotoDTO.self, from: Data(json.utf8))

        XCTAssertNil(photo.caption)
        XCTAssertEqual(photo.takenOnLabel, "3 January 2026")
    }

    func testDecodesNullChildName() throws {
        // A soft-deleted child LEFT JOINs to null child_name; one null must not fail the decode.
        let json = """
        {
          "id": "photo-3",
          "child_id": "00000000-0000-0000-0000-000000000013",
          "child_name": null,
          "caption": "Beach day",
          "taken_on": "2026-08-20",
          "created_at": "2026-07-12T10:00:00+00:00",
          "image_url": "/child-photos/photo-3/image"
        }
        """
        let photo = try decoder.decode(ChildPhotoDTO.self, from: Data(json.utf8))

        XCTAssertNil(photo.childName)
        XCTAssertEqual(photo.childDisplayName, "Unknown")
    }

    func testDecodesUploadResponseEnvelope() throws {
        // POST /child-photos/ returns a batch under a "photos" key.
        let json = """
        {
          "photos": [
            {
              "id": "photo-a",
              "child_id": "00000000-0000-0000-0000-000000000011",
              "child_name": "Child One",
              "caption": null,
              "taken_on": "2026-07-12",
              "created_at": "2026-07-12T10:00:00+00:00",
              "image_url": "/child-photos/photo-a/image"
            },
            {
              "id": "photo-b",
              "child_id": "00000000-0000-0000-0000-000000000011",
              "child_name": "Child One",
              "caption": null,
              "taken_on": "2026-07-13",
              "created_at": "2026-07-13T10:00:00+00:00",
              "image_url": "/child-photos/photo-b/image"
            }
          ]
        }
        """
        let response = try decoder.decode(ChildPhotoUploadResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.photos.count, 2)
        XCTAssertEqual(response.photos.first?.id, "photo-a")
        XCTAssertEqual(response.photos.last?.takenOn, "2026-07-13")
    }

    // MARK: - Capture-date helpers

    func testTakenOnDateRoundTrips() {
        let photo = ChildPhotoDTO(
            id: "x",
            childId: "c",
            childName: "Child One",
            caption: nil,
            takenOn: "2026-07-12",
            location: nil,
            story: nil,
            favourite: false,
            includeInYearbook: true,
            yearbookPosition: nil,
            originalAvailable: true,
            createdAt: "2026-07-12T10:00:00+00:00",
            updatedAt: "2026-07-12T10:00:00+00:00",
            imageUrl: "/child-photos/x/image",
            originalImageUrl: "/child-photos/x/image?size=original"
        )
        let date = try? XCTUnwrap(photo.takenOnDate)
        XCTAssertEqual(ChildPhotoDTO.takenOnValue(from: date ?? Date()), "2026-07-12")
    }

    // MARK: - Update request encoding

    func testUpdateRequestCanClearContextAndEncodeCuration() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(
            ChildPhotoUpdateRequest(
                caption: nil,
                takenOn: "2026-07-12",
                childId: "child-1",
                location: nil,
                story: nil,
                favourite: true,
                includeInYearbook: false
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(object.keys.contains("caption"))
        XCTAssertTrue(object["caption"] is NSNull)
        XCTAssertEqual(object["taken_on"] as? String, "2026-07-12")
        XCTAssertEqual(object["child_id"] as? String, "child-1")
        XCTAssertTrue(object["location"] is NSNull)
        XCTAssertTrue(object["story"] is NSNull)
        XCTAssertEqual(object["favourite"] as? Bool, true)
        XCTAssertEqual(object["include_in_yearbook"] as? Bool, false)
    }
}
