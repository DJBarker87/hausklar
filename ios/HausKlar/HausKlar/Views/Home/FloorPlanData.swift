import CoreGraphics
import Foundation

/// A deliberately fictional fallback layout used only when no operator-owned
/// Home Assistant layout has been configured.
enum FloorPlanData {
    static let viewBoxWidth: CGFloat = 900
    static let viewBoxHeight: CGFloat = 820

    static let groundFloorWalls: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (100, 180, 800, 180), (800, 180, 800, 620),
        (800, 620, 100, 620), (100, 620, 100, 180),
    ]
    static let groundFloorPartitionWalls: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (450, 180, 450, 620),
    ]
    static let firstFloorWalls: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []
    static let firstFloorPartitionWalls: [(CGFloat, CGFloat, CGFloat, CGFloat)] = []

    static let groundFloorStairsRect = CGRect.zero
    static let groundFloorStairsTreads: [CGFloat] = []
    static let stairsTreadX1: CGFloat = 0
    static let stairsTreadX2: CGFloat = 0
    static let firstFloorStairsLine = (CGPoint.zero, CGPoint.zero)
    static let firstFloorStairsTreads: [CGFloat] = []
    static let groundFloorExternalDoors: [CGRect] = [CGRect(x: 430, y: 610, width: 40, height: 20)]
    static let groundFloorInternalDoors: [CGRect] = [CGRect(x: 440, y: 370, width: 20, height: 50)]
    static let firstFloorInternalDoors: [CGRect] = []

    struct RoomLabel {
        let position: CGPoint
        let text: String
        let fontSize: CGFloat
        let opacity: CGFloat
    }
    static let groundFloorLabels = [
        RoomLabel(position: CGPoint(x: 275, y: 400), text: "Example Living Room", fontSize: 18, opacity: 1),
        RoomLabel(position: CGPoint(x: 625, y: 400), text: "Example Kitchen", fontSize: 18, opacity: 1),
    ]
    static let firstFloorLabels: [RoomLabel] = []

    struct CornerBracket { let points: [CGPoint] }
    static let cornerBrackets: [CornerBracket] = []

    struct RoomGlowArea {
        let id: String
        let bounds: CGRect
        let polygon: [CGPoint]?
    }
    static let groundFloorRoomGlows = [
        RoomGlowArea(id: "example_living_room", bounds: CGRect(x: 100, y: 180, width: 350, height: 440), polygon: nil),
        RoomGlowArea(id: "example_kitchen", bounds: CGRect(x: 450, y: 180, width: 350, height: 440), polygon: nil),
    ]
    static let firstFloorRoomGlows: [RoomGlowArea] = []

    static let defaultDevices: [(id: String, entityId: String, type: String, floor: Int, x: CGFloat, y: CGFloat, room: String, label: String)] = [
        ("example_lamp", "light.example_living_room", "light", 0, 275, 400, "example_living_room", "Example lamp"),
        ("example_temperature", "sensor.example_temperature", "temperature", 0, 625, 400, "example_kitchen", "Example temperature"),
    ]

    static let demoNameMap: [String: String] = [:]
    static func demoLabel(_ label: String, isDemoMode: Bool) -> String { label }

    struct DefaultRoom {
        let id: String
        let floor: Int
        let label: String
        let bounds: CGRect
        let lightEntities: [String]
        let polygon: [[CGFloat]]?
    }
    static let defaultRooms = [
        DefaultRoom(id: "example_living_room", floor: 0, label: "Example Living Room", bounds: CGRect(x: 100, y: 180, width: 350, height: 440), lightEntities: ["light.example_living_room"], polygon: nil),
        DefaultRoom(id: "example_kitchen", floor: 0, label: "Example Kitchen", bounds: CGRect(x: 450, y: 180, width: 350, height: 440), lightEntities: [], polygon: nil),
    ]

    struct CameraDefinition {
        let id: String
        let entityId: String
        let motionEntityId: String
        let eventSelectId: String
        let cx: CGFloat
        let cy: CGFloat
        let label: String
    }
    static let cameras: [CameraDefinition] = []
}
