import XCTest
@testable import HausKlar

final class MemoryDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testDecodesMemoriesContract() throws {
        let json = """
        {
          "generated_at": "2026-07-12T06:00:00+00:00",
          "memories": [
            {
              "asset_id": "a1",
              "taken_at": "2025-07-12T14:03:00+01:00",
              "years_ago": 1,
              "thumbnail_url": "/photos/a1/thumbnail?size=preview"
            },
            {
              "asset_id": "a2",
              "taken_at": "2023-07-12T09:00:00+01:00",
              "years_ago": 3,
              "thumbnail_url": "/photos/a2/thumbnail?size=preview"
            }
          ]
        }
        """
        let response = try decoder.decode(PhotoMemoriesResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.memories.count, 2)
        XCTAssertEqual(response.memories[0].assetId, "a1")
        XCTAssertEqual(response.memories[0].thumbnailUrl, "/photos/a1/thumbnail?size=preview")
        XCTAssertNotNil(ISODateParser.parse(try XCTUnwrap(response.memories[0].takenAt)))
    }

    func testDecodesNullTakenAt() throws {
        // An Immich asset may lack a capture timestamp; a null must not drop the memory.
        let json = #"{"generated_at": "2026-07-12T06:00:00+00:00", "memories": [{"asset_id": "a3", "taken_at": null, "years_ago": 2, "thumbnail_url": "/photos/a3/thumbnail"}]}"#
        let response = try decoder.decode(PhotoMemoriesResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.memories.count, 1)
        XCTAssertNil(response.memories[0].takenAt)
        XCTAssertEqual(response.memories[0].caption, "2 years ago")
    }

    func testDecodesEmptyMemories() throws {
        let json = #"{"generated_at": "2026-07-12T06:00:00+00:00", "memories": []}"#
        let response = try decoder.decode(PhotoMemoriesResponseDTO.self, from: Data(json.utf8))
        XCTAssertTrue(response.memories.isEmpty)
    }

    func testCaptionPluralisesYearsAgo() {
        func memory(_ yearsAgo: Int) -> PhotoMemoryDTO {
            PhotoMemoryDTO(assetId: "a", takenAt: "2025-07-12T14:03:00+01:00", yearsAgo: yearsAgo, thumbnailUrl: "/photos/a/thumbnail")
        }
        XCTAssertEqual(memory(1).caption, "One year ago")
        XCTAssertEqual(memory(2).caption, "2 years ago")
    }
}
