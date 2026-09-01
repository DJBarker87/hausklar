import Foundation
import CoreGraphics

/// Top-level response from the dashboard config API (GET /api/config).
struct FloorPlanConfig: Codable {
    let rooms: [FloorPlanRoom]
    let devices: [FloorPlanDevice]
}

struct FloorPlanRoom: Codable, Identifiable {
    let id: String
    let floor: Int
    let label: String
    let bounds: FloorPlanBounds
    let lightEntities: [String]
    let polygon: [[CGFloat]]?

    enum CodingKeys: String, CodingKey {
        case id, floor, label, bounds, polygon
        case lightEntities = "light_entities"
    }
}

struct FloorPlanBounds: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct FloorPlanDevice: Codable, Identifiable, Hashable {
    let id: String
    let entityId: String
    let type: String
    let floor: Int
    let x: CGFloat
    let y: CGFloat
    let room: String
    let label: String

    enum CodingKeys: String, CodingKey {
        case id, type, floor, x, y, room, label
        case entityId = "entity_id"
    }
}
