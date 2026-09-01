import UIKit
import XCTest

@testable import HausKlar

@MainActor
final class HomeNetworkBoundaryTests: XCTestCase {
    private func temporaryFile(containing data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-response-\(UUID().uuidString)")
        try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    func testHomeLayoutMapsAuthenticatedDTOWithStrictIdentifiersAndBounds() throws {
        let response = HomeLayoutDTO(
            width: 900,
            height: 820,
            floors: [
                .init(
                    id: 0,
                    name: "Ground floor",
                    rooms: [
                        .init(
                            id: "kitchen",
                            label: "Kitchen",
                            bounds: .init(x: 100, y: 100, width: 300, height: 200),
                            polygon: [[100, 100], [400, 100], [400, 300], [100, 300]],
                            lightEntityIds: ["light.example_3f2a461f"]
                        )
                    ]
                )
            ],
            devices: [
                .init(
                    id: "light_kitchen",
                    entityId: "light.example_3f2a461f",
                    type: "light",
                    floor: 0,
                    x: 200,
                    y: 200,
                    room: "kitchen",
                    label: "Kitchen light"
                )
            ]
        )

        let result = try ConfigAPIClient.map(response)

        XCTAssertEqual(result.rooms.map(\.id), ["kitchen"])
        XCTAssertEqual(result.devices.map(\.entityId), ["light.example_3f2a461f"])
    }

    func testHomeLayoutRejectsOutOfBoundsAndDuplicateDeviceAuthority() {
        let response = HomeLayoutDTO(
            width: 100,
            height: 100,
            floors: [
                .init(
                    id: 0,
                    name: "Ground",
                    rooms: [
                        .init(
                            id: "room",
                            label: "Room",
                            bounds: .init(x: 0, y: 0, width: 100, height: 100),
                            polygon: nil,
                            lightEntityIds: []
                        )
                    ]
                )
            ],
            devices: [
                .init(
                    id: "one",
                    entityId: "light.same",
                    type: "light",
                    floor: 0,
                    x: 101,
                    y: 10,
                    room: "room",
                    label: "One"
                ),
                .init(
                    id: "two",
                    entityId: "light.same",
                    type: "light",
                    floor: 0,
                    x: 10,
                    y: 10,
                    room: "room",
                    label: "Two"
                ),
            ]
        )

        XCTAssertThrowsError(try ConfigAPIClient.map(response))
    }

    func testHomeIdentifierValidationRejectsPathAndCrossDomainValues() {
        XCTAssertTrue(HAClient.validCameraEntityID("camera.front_door"))
        XCTAssertFalse(HAClient.validCameraEntityID("sensor.front_door"))
        XCTAssertFalse(HAClient.validCameraEntityID("camera../secret"))

        XCTAssertTrue(AudiobookService.validIdentifier("book-123_ABC"))
        XCTAssertFalse(AudiobookService.validIdentifier("../book"))
        XCTAssertFalse(AudiobookService.validIdentifier("book/cover"))
        XCTAssertTrue(AudiobookService.validMediaPlayerEntityID("media_player.example_2da32186"))
        XCTAssertFalse(AudiobookService.validMediaPlayerEntityID("light.example_ff6f3185"))
    }

    func testCameraImageDimensionValidationCannotOverflow() {
        XCTAssertTrue(HAClient.safeImageDimensions(width: 4_000, height: 3_000))
        XCTAssertFalse(HAClient.safeImageDimensions(width: 8_192, height: 8_192))
        XCTAssertFalse(HAClient.safeImageDimensions(width: Int64.max, height: Int64.max))
        XCTAssertFalse(HAClient.safeImageDimensions(width: -1, height: Int64.max))
        XCTAssertFalse(HAClient.safeImageDimensions(width: 0, height: 1))
    }

    func testBoundedDownloadRequiresAllowedMIMEAndEnforcesActualFileSize() throws {
        let file = try temporaryFile(containing: Data(repeating: 0x41, count: 16))
        let validResponse = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://localhost:8001/api/briefing/glance")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json; charset=utf-8"]
            )
        )

        XCTAssertEqual(
            try BoundedHTTPPayload.readDownload(
                at: file,
                response: validResponse,
                allowedMediaTypes: ["application/json"],
                maximumBytes: 16
            ).count,
            16
        )
        XCTAssertThrowsError(
            try BoundedHTTPPayload.readDownload(
                at: file,
                response: validResponse,
                allowedMediaTypes: ["application/json"],
                maximumBytes: 15
            )
        )

        let mislabeledResponse = try XCTUnwrap(
            HTTPURLResponse(
                url: validResponse.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )
        )
        XCTAssertThrowsError(
            try BoundedHTTPPayload.readDownload(
                at: file,
                response: mislabeledResponse,
                allowedMediaTypes: ["application/json"],
                maximumBytes: 16
            )
        )
    }

    func testBoundedImageDownloadRejectsNonImageAndPathLikeAssetIDs() throws {
        XCTAssertTrue(BoundedHTTPPayload.isValidOpaqueIdentifier("asset-123"))
        XCTAssertFalse(BoundedHTTPPayload.isValidOpaqueIdentifier("../asset-123"))
        XCTAssertFalse(BoundedHTTPPayload.isValidOpaqueIdentifier("asset/123"))
        XCTAssertFalse(BoundedHTTPPayload.isValidOpaqueIdentifier("photo-💥"))

        let file = try temporaryFile(containing: Data("not an image".utf8))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "http://localhost:8001/api/photos/asset-123/thumbnail")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg"]
            )
        )
        XCTAssertThrowsError(
            try BoundedHTTPPayload.readDownload(
                at: file,
                response: response,
                allowedMediaTypes: ["image/jpeg"],
                maximumBytes: 1_024,
                imageLimits: .init(
                    maximumWidth: 4_096,
                    maximumHeight: 4_096,
                    maximumPixels: 16_000_000
                )
            )
        )
    }

    @MainActor
    func testHomeMediaThumbnailAcceptsOnlyOpaqueHausKlarProxyPaths() throws {
        let token = String(repeating: "a", count: 32)
        let accepted = try XCTUnwrap(
            SpotifyBrowseViewModel.thumbnailProxyPath(
                from: "/home/media/thumbnails/\(token)"
            )
        )
        XCTAssertEqual(
            try accepted.validatedValue(),
            "/home/media/thumbnails/\(token)"
        )

        for unsafe in [
            "https://i.scdn.co/image/private",
            "http://192.0.2.108:8123/local/cover.jpg",
            "/home/media/thumbnails/\(token)?url=https://evil.example",
            "/home/media/thumbnails/../secrets",
            "/home/media/thumbnails/\(String(repeating: "A", count: 32))",
            "/photos/\(token)/thumbnail",
        ] {
            XCTAssertNil(
                SpotifyBrowseViewModel.thumbnailProxyPath(from: unsafe),
                unsafe
            )
        }
    }

    func testHomeMediaThumbnailSourceDimensionChecksAreFiniteAndOverflowSafe() {
        XCTAssertTrue(
            HomeMediaThumbnailService.safeSourceDimensions(width: 4_000, height: 4_000)
        )
        XCTAssertFalse(
            HomeMediaThumbnailService.safeSourceDimensions(width: 8_192, height: 8_192)
        )
        XCTAssertFalse(
            HomeMediaThumbnailService.safeSourceDimensions(
                width: Int64.max,
                height: Int64.max
            )
        )
        XCTAssertFalse(
            HomeMediaThumbnailService.safeSourceDimensions(width: -1, height: 100)
        )
    }

    @MainActor
    func testHomeMediaThumbnailDownsamplesAndRejectsOversizedEncodedData() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160))
        let source = renderer.pngData { context in
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        }

        let thumbnail = try XCTUnwrap(
            HomeMediaThumbnailService.downsample(source, maximumPixelSize: 64)
        )
        XCTAssertLessThanOrEqual(thumbnail.cgImage?.width ?? .max, 64)
        XCTAssertLessThanOrEqual(thumbnail.cgImage?.height ?? .max, 64)
        XCTAssertNil(
            HomeMediaThumbnailService.downsample(
                Data(count: HomeMediaThumbnailService.maximumDownloadBytes + 1),
                maximumPixelSize: 64
            )
        )
        XCTAssertNil(
            HomeMediaThumbnailService.downsample(source, maximumPixelSize: 2_000)
        )
    }

    @MainActor
    func testHomeMediaThumbnailCacheIsBoundedToCurrentOwner() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let source = renderer.jpegData(withCompressionQuality: 0.9) { context in
            context.cgContext.setFillColor(UIColor.systemGreen.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let token = String(repeating: "b", count: 32)
        let path = try XCTUnwrap(
            SpotifyBrowseViewModel.thumbnailProxyPath(
                from: "/home/media/thumbnails/\(token)"
            )
        )
        var owner: String? = "family-a:dom"
        var fetchCount = 0
        var fetchedPaths: [String] = []
        let service = HomeMediaThumbnailService(
            dataLoader: { requestedPath, _ in
                fetchCount += 1
                fetchedPaths.append(try requestedPath.validatedValue())
                return source
            },
            ownerIdentity: { owner }
        )

        let firstOwnerImage = await service.image(for: path, maximumPixelSize: 96)
        let cachedFirstOwnerImage = await service.image(for: path, maximumPixelSize: 96)
        XCTAssertNotNil(firstOwnerImage)
        XCTAssertNotNil(cachedFirstOwnerImage)
        XCTAssertEqual(fetchCount, 1, "The decoded image should be reused for one owner")

        owner = "family-b:kat"
        let secondOwnerImage = await service.image(for: path, maximumPixelSize: 96)
        XCTAssertNotNil(secondOwnerImage)
        XCTAssertEqual(fetchCount, 2, "Changing owner must purge and refetch private artwork")

        owner = nil
        let loggedOutImage = await service.image(for: path, maximumPixelSize: 96)
        XCTAssertNil(loggedOutImage)
        XCTAssertEqual(fetchCount, 2, "An unauthenticated request must not reach transport")
        owner = "family-b:kat"
        let postLogoutImage = await service.image(for: path, maximumPixelSize: 96)
        XCTAssertNotNil(postLogoutImage)
        XCTAssertEqual(fetchCount, 3, "Logout must purge the prior owner's decoded image")
        XCTAssertEqual(
            fetchedPaths,
            Array(repeating: "/home/media/thumbnails/\(token)", count: 3)
        )
    }
}
