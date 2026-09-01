import CoreGraphics
import Foundation

struct HomeLayoutDTO: Decodable {
    let width: Double
    let height: Double
    let floors: [Floor]
    let devices: [Device]?

    struct Floor: Decodable {
        let id: Int
        let name: String
        let rooms: [Room]
    }

    struct Room: Decodable {
        let id: String
        let label: String
        let bounds: Bounds
        let polygon: [[Double]]?
        let lightEntityIds: [String]
    }

    struct Bounds: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Device: Decodable {
        let id: String
        let entityId: String
        let type: String
        let floor: Int
        let x: Double
        let y: Double
        let room: String
        let label: String
    }
}

enum HomeLayoutMappingError: Error, Equatable {
    case invalidLayout
}

/// Fetches private device positions and room geometry through the authenticated
/// HausKlar API. The app never discovers or calls the dashboard's LAN address.
@MainActor
final class ConfigAPIClient {
    static let shared = ConfigAPIClient()

    func fetchConfig() async throws -> FloorPlanConfig {
        let response: HomeLayoutDTO = try await APIClient.shared.get(
            "/home/layout",
            cachePolicy: .networkThenStale
        )
        return try Self.map(response)
    }

    static func map(_ response: HomeLayoutDTO) throws -> FloorPlanConfig {
        guard validDimension(response.width, maximum: 20_000),
              validDimension(response.height, maximum: 20_000),
              !response.floors.isEmpty,
              response.floors.count <= 10,
              Set(response.floors.map(\.id)).count == response.floors.count else {
            throw HomeLayoutMappingError.invalidLayout
        }

        var roomIDs = Set<String>()
        var rooms: [FloorPlanRoom] = []
        for floor in response.floors {
            guard (0...9).contains(floor.id),
                  !floor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  floor.rooms.count <= 100 else {
                throw HomeLayoutMappingError.invalidLayout
            }
            for room in floor.rooms {
                let bounds = room.bounds
                guard validIdentifier(room.id),
                      roomIDs.insert(room.id).inserted,
                      validLabel(room.label),
                      validCoordinate(bounds.x, maximum: response.width),
                      validCoordinate(bounds.y, maximum: response.height),
                      validDimension(bounds.width, maximum: response.width),
                      validDimension(bounds.height, maximum: response.height),
                      bounds.x + bounds.width <= response.width,
                      bounds.y + bounds.height <= response.height,
                      room.lightEntityIds.count <= 30,
                      room.lightEntityIds.allSatisfy(validEntityID) else {
                    throw HomeLayoutMappingError.invalidLayout
                }
                let polygon: [[CGFloat]]?
                if let values = room.polygon {
                    guard (3...30).contains(values.count),
                          values.allSatisfy({ point in
                              point.count == 2
                                  && validCoordinate(point[0], maximum: response.width)
                                  && validCoordinate(point[1], maximum: response.height)
                          }) else {
                        throw HomeLayoutMappingError.invalidLayout
                    }
                    polygon = values.map { [CGFloat($0[0]), CGFloat($0[1])] }
                } else {
                    polygon = nil
                }
                rooms.append(
                    FloorPlanRoom(
                        id: room.id,
                        floor: floor.id,
                        label: room.label,
                        bounds: FloorPlanBounds(
                            x: CGFloat(bounds.x),
                            y: CGFloat(bounds.y),
                            width: CGFloat(bounds.width),
                            height: CGFloat(bounds.height)
                        ),
                        lightEntities: room.lightEntityIds,
                        polygon: polygon
                    )
                )
            }
        }

        let sourceDevices: [HomeLayoutDTO.Device]
        if let devices = response.devices, !devices.isEmpty {
            sourceDevices = devices
        } else {
            // Older servers authenticated the geometry but did not yet include
            // the device-position array. Preserve the same calm offline result
            // until that server is upgraded; every local fallback row is still
            // subjected to the same bounds and identifier checks below.
            sourceDevices = FloorPlanData.defaultDevices.map {
                HomeLayoutDTO.Device(
                    id: $0.id,
                    entityId: $0.entityId,
                    type: $0.type,
                    floor: $0.floor,
                    x: Double($0.x),
                    y: Double($0.y),
                    room: $0.room,
                    label: $0.label
                )
            }
        }

        guard sourceDevices.count <= 300 else {
            throw HomeLayoutMappingError.invalidLayout
        }
        let allowedTypes: Set<String> = [
            "appliance", "boiler", "camera", "contact", "light", "motion", "plug",
            "speaker", "temperature", "trv",
        ]
        var deviceIDs = Set<String>()
        var entityIDs = Set<String>()
        let floorIDs = Set(response.floors.map(\.id))
        let devices = try sourceDevices.map { device in
            guard validIdentifier(device.id),
                  deviceIDs.insert(device.id).inserted,
                  validEntityID(device.entityId),
                  entityIDs.insert(device.entityId).inserted,
                  allowedTypes.contains(device.type),
                  floorIDs.contains(device.floor),
                  validCoordinate(device.x, maximum: response.width),
                  validCoordinate(device.y, maximum: response.height),
                  validIdentifier(device.room),
                  validLabel(device.label) else {
                throw HomeLayoutMappingError.invalidLayout
            }
            return FloorPlanDevice(
                id: device.id,
                entityId: device.entityId,
                type: device.type,
                floor: device.floor,
                x: CGFloat(device.x),
                y: CGFloat(device.y),
                room: device.room,
                label: device.label
            )
        }
        return FloorPlanConfig(rooms: rooms, devices: devices)
    }

    /// Build FloorPlanConfig from bundled defaults for explicit demo mode and
    /// for the first launch when no authenticated response is cached yet.
    func fallbackConfig() -> FloorPlanConfig {
        let rooms = FloorPlanData.defaultRooms.map { room in
            FloorPlanRoom(
                id: room.id,
                floor: room.floor,
                label: room.label,
                bounds: FloorPlanBounds(
                    x: room.bounds.origin.x,
                    y: room.bounds.origin.y,
                    width: room.bounds.size.width,
                    height: room.bounds.size.height
                ),
                lightEntities: room.lightEntities,
                polygon: room.polygon
            )
        }
        let devices = FloorPlanData.defaultDevices.map { device in
            FloorPlanDevice(
                id: device.id,
                entityId: device.entityId,
                type: device.type,
                floor: device.floor,
                x: device.x,
                y: device.y,
                room: device.room,
                label: device.label
            )
        }
        return FloorPlanConfig(rooms: rooms, devices: devices)
    }

    private static func validCoordinate(_ value: Double, maximum: Double) -> Bool {
        value.isFinite && value >= 0 && value <= maximum
    }

    private static func validDimension(_ value: Double, maximum: Double) -> Bool {
        value.isFinite && value > 0 && value <= maximum
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.allSatisfy {
            $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
        }
    }

    private static func validEntityID(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces.allSatisfy { part in
            !part.isEmpty && part.count <= 100 && part.allSatisfy {
                $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
            }
        }
    }

    private static func validLabel(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.count <= 100
            && trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    }
}
