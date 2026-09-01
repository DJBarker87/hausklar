import XCTest
@testable import HausKlar

final class PhotoSearchDTOTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testDecodesSearchResponseContract() throws {
        let json = """
        {
          "query": "beach",
          "results": [
            {"asset_id": "abc123def456", "taken_at": "2025-08-01T14:30:00+00:00", "thumbnail_url": "/photos/abc123def456/thumbnail?size=preview"},
            {"asset_id": "zyx987wvu654", "taken_at": null, "thumbnail_url": "/photos/zyx987wvu654/thumbnail?size=preview"}
          ]
        }
        """
        let response = try decoder.decode(PhotoSearchResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.query, "beach")
        XCTAssertEqual(response.results.count, 2)

        let first = response.results[0]
        XCTAssertEqual(first.id, "abc123def456")
        XCTAssertEqual(first.assetId, "abc123def456")
        XCTAssertEqual(first.thumbnailUrl, "/photos/abc123def456/thumbnail?size=preview")
        XCTAssertNotNil(first.takenAtDisplay)

        let second = response.results[1]
        XCTAssertNil(second.takenAt)
        XCTAssertNil(second.takenAtDisplay)
    }

    func testDecodesEmptyResults() throws {
        let json = #"{"query": "unicorn", "results": []}"#
        let response = try decoder.decode(PhotoSearchResponseDTO.self, from: Data(json.utf8))

        XCTAssertEqual(response.query, "unicorn")
        XCTAssertTrue(response.results.isEmpty)
    }
}
