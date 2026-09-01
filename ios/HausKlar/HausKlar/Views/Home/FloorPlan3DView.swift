import SwiftUI
import SceneKit

/// SceneKit-based 3D floor plan view matching the React Three Fiber dashboard.
/// Coordinate mapping: worldX = (svgX - 450) * 0.01, worldZ = (svgY - 410) * 0.01
struct FloorPlan3DView: UIViewRepresentable {
    let floor: Int
    let devices: [FloorPlanDevice]
    let entities: [String: HAEntity]
    let roomConfigs: [FloorPlanRoom]
    var meshMode: Bool = false
    var isDemoMode: Bool = false
    var zhaLqi: [String: Int] = [:]
    var onDeviceTap: ((FloorPlanDevice) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X
        scnView.autoenablesDefaultLighting = false

        context.coordinator.onDeviceTap = onDeviceTap
        context.coordinator.meshMode = meshMode
        context.coordinator.isDemoMode = isDemoMode
        context.coordinator.buildScene(
            floor: floor,
            devices: devices,
            entities: entities,
            roomConfigs: roomConfigs
        )
        scnView.scene = context.coordinator.scene

        // Camera controller limits
        let controller = scnView.defaultCameraController
        controller.minimumVerticalAngle = -5
        controller.maximumVerticalAngle = 85

        // Tap gesture for device selection
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tap)
        context.coordinator.scnView = scnView

        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        context.coordinator.onDeviceTap = onDeviceTap
        context.coordinator.meshMode = meshMode
        context.coordinator.isDemoMode = isDemoMode
        context.coordinator.zhaLqi = zhaLqi

        if context.coordinator.currentFloor != floor {
            context.coordinator.buildScene(
                floor: floor,
                devices: devices,
                entities: entities,
                roomConfigs: roomConfigs
            )
            scnView.scene = context.coordinator.scene
            return
        }
        context.coordinator.updateDeviceStates(entities: entities, roomConfigs: roomConfigs)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var scene = SCNScene()
        var currentFloor: Int = -1
        var deviceNodes: [String: SCNNode] = [:]
        var roomFloorNodes: [String: SCNNode] = [:]
        var deviceMap: [String: FloorPlanDevice] = [:]
        var onDeviceTap: ((FloorPlanDevice) -> Void)?
        var meshMode: Bool = false
        var isDemoMode: Bool = false
        var zhaLqi: [String: Int] = [:]
        weak var scnView: SCNView?

        // Constants
        private let wallHeight: Float = 0.4
        private let wallThickness: Float = 0.02
        private let svgScale: Float = 0.01
        private let svgCenterX: Float = 450
        private let svgCenterY: Float = 410
        private let greenColor = UIColor.hackerGreen

        // MARK: - Coordinate Mapping

        func svgToWorld(_ svgX: CGFloat, _ svgY: CGFloat) -> SCNVector3 {
            let wx = (Float(svgX) - svgCenterX) * svgScale
            let wz = (Float(svgY) - svgCenterY) * svgScale
            return SCNVector3(wx, 0, wz)
        }

        // MARK: - Scene Building

        func buildScene(floor: Int, devices: [FloorPlanDevice], entities: [String: HAEntity], roomConfigs: [FloorPlanRoom]) {
            currentFloor = floor
            deviceNodes.removeAll()
            roomFloorNodes.removeAll()
            deviceMap.removeAll()

            let newScene = SCNScene()
            newScene.background.contents = UIColor.black

            // Camera
            let cameraNode = buildCamera()
            newScene.rootNode.addChildNode(cameraNode)

            // Ambient light
            let lightNode = SCNNode()
            let ambientLight = SCNLight()
            ambientLight.type = .ambient
            ambientLight.intensity = 300
            ambientLight.color = UIColor.white
            lightNode.light = ambientLight
            newScene.rootNode.addChildNode(lightNode)

            // Directional light for sphere highlights
            let dirLightNode = SCNNode()
            let directionalLight = SCNLight()
            directionalLight.type = .directional
            directionalLight.intensity = 400
            directionalLight.color = UIColor.white
            dirLightNode.light = directionalLight
            dirLightNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
            newScene.rootNode.addChildNode(dirLightNode)

            // Grid
            newScene.rootNode.addChildNode(buildGrid())

            // Walls
            let walls = floor == 0 ? FloorPlanData.groundFloorWalls : FloorPlanData.firstFloorWalls
            for (x1, y1, x2, y2) in walls {
                newScene.rootNode.addChildNode(buildWallNode(x1: x1, y1: y1, x2: x2, y2: y2))
            }

            // Partition walls
            let partitions = floor == 0 ? FloorPlanData.groundFloorPartitionWalls : FloorPlanData.firstFloorPartitionWalls
            for (x1, y1, x2, y2) in partitions {
                newScene.rootNode.addChildNode(buildWallNode(x1: x1, y1: y1, x2: x2, y2: y2, fillAlpha: 0.45, wireAlpha: 0.3))
            }

            // Room floors
            let glows = floor == 0 ? FloorPlanData.groundFloorRoomGlows : FloorPlanData.firstFloorRoomGlows
            for glow in glows {
                let roomConfig = roomConfigs.first { $0.id == glow.id }
                let lightEntities = roomConfig?.lightEntities ?? []
                let anyLightOn = lightEntities.contains { entities[$0]?.isOn == true }
                let transparency: CGFloat = anyLightOn ? 0.25 : 0.02

                let node: SCNNode
                if let polygon = glow.polygon {
                    node = buildPolygonFloor(polygon: polygon)
                } else {
                    node = buildRectFloor(bounds: glow.bounds)
                }
                if let mat = node.geometry?.firstMaterial {
                    mat.transparency = transparency
                }
                roomFloorNodes[glow.id] = node
                newScene.rootNode.addChildNode(node)
            }

            // Device markers
            let floorDevices = devices.filter { $0.floor == floor }
            for device in floorDevices {
                let entity = entities[device.entityId]
                let markerNode = buildDeviceMarker(device: device, entity: entity)
                deviceNodes[device.id] = markerNode
                deviceMap[device.id] = device
                newScene.rootNode.addChildNode(markerNode)
            }

            // Camera markers (ground floor only) — same style as other devices
            if floor == 0 {
                for camera in FloorPlanData.cameras {
                    let camDevice = FloorPlanDevice(
                        id: camera.id, entityId: camera.entityId,
                        type: "camera", floor: 0,
                        x: camera.cx, y: camera.cy,
                        room: "", label: camera.label
                    )
                    let camEntity = entities[camera.entityId]
                    let camNode = buildDeviceMarker(device: camDevice, entity: camEntity)
                    deviceNodes[camera.id] = camNode
                    deviceMap[camera.id] = camDevice
                    newScene.rootNode.addChildNode(camNode)
                }
            }

            // Room labels
            let labels = floor == 0 ? FloorPlanData.groundFloorLabels : FloorPlanData.firstFloorLabels
            for label in labels {
                let labelNode = buildRoomLabel(label)
                newScene.rootNode.addChildNode(labelNode)
            }

            scene = newScene
        }

        // MARK: - Room Labels

        private func buildRoomLabel(_ label: FloorPlanData.RoomLabel) -> SCNNode {
            let pos = svgToWorld(label.position.x, label.position.y)

            let displayText = FloorPlanData.demoLabel(label.text, isDemoMode: isDemoMode)
            let textGeo = SCNText(string: displayText, extrusionDepth: 0)
            textGeo.font = UIFont.monospacedSystemFont(ofSize: label.fontSize * 0.8, weight: .regular)
            textGeo.flatness = 0.3

            let mat = SCNMaterial()
            mat.diffuse.contents = UIColor.hackerGrey.withAlphaComponent(label.opacity)
            mat.lightingModel = .constant
            textGeo.materials = [mat]

            let textNode = SCNNode(geometry: textGeo)

            // SCNText origin is bottom-left — center it
            let (min, max) = textNode.boundingBox
            let textWidth = max.x - min.x
            let textHeight = max.y - min.y
            textNode.pivot = SCNMatrix4MakeTranslation(
                min.x + textWidth / 2,
                min.y + textHeight / 2,
                0
            )

            // Scale down to world units (text is in points, world is ~0.01 per SVG unit)
            let worldScale: Float = svgScale * 0.48
            textNode.scale = SCNVector3(worldScale, worldScale, worldScale)

            // Lay flat on the floor: rotate -90° around X
            textNode.eulerAngles.x = -.pi / 2
            textNode.position = SCNVector3(pos.x, 0.002, pos.z)

            return textNode
        }

        // MARK: - Camera

        private func buildCamera() -> SCNNode {
            let camera = SCNCamera()
            camera.fieldOfView = 45
            camera.zNear = 0.1
            camera.zFar = 50

            let node = SCNNode()
            node.camera = camera
            node.position = SCNVector3(0, 8, 6)
            node.look(at: SCNVector3(0, 0, 0))
            return node
        }

        // MARK: - Grid

        private func buildGrid() -> SCNNode {
            let gridPlane = SCNPlane(width: 20, height: 20)
            let mat = SCNMaterial()
            mat.lightingModel = .constant
            mat.isDoubleSided = true

            // Generate a grid texture
            let texSize = 400
            let cellSize = 20 // 20 cells across 400px = 20x20 grid
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: texSize, height: texSize))
            let gridImage = renderer.image { ctx in
                UIColor.clear.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: texSize, height: texSize))

                UIColor.hackerGreen.withAlphaComponent(0.15).setStroke()
                let bezier = UIBezierPath()
                bezier.lineWidth = 0.5
                for i in 0...texSize/cellSize {
                    let pos = CGFloat(i * cellSize)
                    bezier.move(to: CGPoint(x: pos, y: 0))
                    bezier.addLine(to: CGPoint(x: pos, y: CGFloat(texSize)))
                    bezier.move(to: CGPoint(x: 0, y: pos))
                    bezier.addLine(to: CGPoint(x: CGFloat(texSize), y: pos))
                }
                bezier.stroke()
            }

            mat.diffuse.contents = gridImage
            gridPlane.materials = [mat]

            let node = SCNNode(geometry: gridPlane)
            node.eulerAngles.x = -.pi / 2
            node.position.y = -0.01
            return node
        }

        // MARK: - Walls

        private func buildWallNode(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat,
                                   fillAlpha: CGFloat = 0.8, wireAlpha: CGFloat = 0.6) -> SCNNode {
            let mid = svgToWorld((x1 + x2) / 2, (y1 + y2) / 2)
            let dx = Float(x2 - x1) * svgScale
            let dz = Float(y2 - y1) * svgScale
            let length = sqrt(dx * dx + dz * dz)
            let angle = atan2(dx, dz)

            let box = SCNBox(width: CGFloat(wallThickness), height: CGFloat(wallHeight),
                             length: CGFloat(length), chamferRadius: 0)
            let fillMat = SCNMaterial()
            fillMat.diffuse.contents = UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: fillAlpha)
            fillMat.lightingModel = .constant
            box.materials = [fillMat]

            let node = SCNNode(geometry: box)
            node.position = SCNVector3(mid.x, wallHeight / 2, mid.z)
            node.eulerAngles.y = angle

            // Wireframe overlay
            let wireBox = SCNBox(width: CGFloat(wallThickness) + 0.001, height: CGFloat(wallHeight) + 0.001,
                                 length: CGFloat(length) + 0.001, chamferRadius: 0)
            let wireMat = SCNMaterial()
            wireMat.diffuse.contents = UIColor.hackerGreen.withAlphaComponent(wireAlpha)
            wireMat.lightingModel = .constant
            wireMat.fillMode = .lines
            wireBox.materials = [wireMat]
            let wireNode = SCNNode(geometry: wireBox)
            node.addChildNode(wireNode)

            return node
        }

        // MARK: - Room Floors

        private func buildRectFloor(bounds: CGRect) -> SCNNode {
            let w = Float(bounds.width) * svgScale
            let h = Float(bounds.height) * svgScale
            let plane = SCNPlane(width: CGFloat(w), height: CGFloat(h))
            let mat = SCNMaterial()
            mat.diffuse.contents = greenColor
            mat.lightingModel = .constant
            mat.transparency = 0.02
            mat.isDoubleSided = true
            plane.materials = [mat]

            let center = svgToWorld(bounds.midX, bounds.midY)
            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = -.pi / 2
            node.position = SCNVector3(center.x, 0.001, center.z)
            return node
        }

        private func buildPolygonFloor(polygon: [CGPoint]) -> SCNNode {
            guard polygon.count >= 3 else { return SCNNode() }

            let path = UIBezierPath()
            let worldPts = polygon.map { pt -> CGPoint in
                let wx = CGFloat((Float(pt.x) - svgCenterX) * svgScale)
                let wz = CGFloat((Float(pt.y) - svgCenterY) * svgScale)
                return CGPoint(x: wx, y: -wz) // Negate Z for SCNShape XY plane
            }

            path.move(to: worldPts[0])
            for pt in worldPts.dropFirst() {
                path.addLine(to: pt)
            }
            path.close()

            let shape = SCNShape(path: path, extrusionDepth: 0.001)
            let mat = SCNMaterial()
            mat.diffuse.contents = greenColor
            mat.lightingModel = .constant
            mat.transparency = 0.02
            mat.isDoubleSided = true
            shape.materials = [mat]

            let node = SCNNode(geometry: shape)
            node.eulerAngles.x = -.pi / 2
            node.position.y = 0.001
            return node
        }

        // MARK: - Device Markers

        private func buildDeviceMarker(device: FloorPlanDevice, entity: HAEntity?) -> SCNNode {
            let pos = svgToWorld(device.x, device.y)

            let (color, opacity) = DeviceColors.uiColor(for: device.type, entity: entity)
            let radius = markerRadius(for: device.type)
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = 24

            let mat = SCNMaterial()
            mat.diffuse.contents = color.withAlphaComponent(opacity)
            mat.lightingModel = .phong
            mat.specular.contents = UIColor.white.withAlphaComponent(0.4)
            mat.shininess = 0.6
            mat.fresnelExponent = 1.5
            sphere.materials = [mat]

            let markerNode = SCNNode(geometry: sphere)
            markerNode.name = device.id
            markerNode.position = SCNVector3(pos.x, 0.25, pos.z)

            // Invisible hit-test sphere (larger for easy tapping on mobile)
            let hitSphere = SCNSphere(radius: 0.12)
            let hitMat = SCNMaterial()
            hitMat.diffuse.contents = UIColor.clear
            hitMat.lightingModel = .constant
            hitSphere.materials = [hitMat]
            let hitNode = SCNNode(geometry: hitSphere)
            hitNode.name = device.id
            hitNode.opacity = 0.001
            markerNode.addChildNode(hitNode)

            return markerNode
        }

        private func markerRadius(for type: String) -> CGFloat {
            switch type {
            case "appliance":
                return 0.06
            case "motion", "temperature", "contact":
                return 0.05
            default:
                return 0.06
            }
        }

        // MARK: - Tap Handling

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let scnView = scnView else { return }
            let location = gesture.location(in: scnView)
            let hitResults = scnView.hitTest(location, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue,
                .boundingBoxOnly: true,
            ])

            for hit in hitResults {
                let node = hit.node
                if let deviceId = node.name, let device = deviceMap[deviceId] {
                    HapticManager.light()
                    onDeviceTap?(device)
                    return
                }
                // Check parent (hit node might be the invisible plane child)
                if let parentId = node.parent?.name, let device = deviceMap[parentId] {
                    HapticManager.light()
                    onDeviceTap?(device)
                    return
                }
            }
        }

        // MARK: - State Updates

        func updateDeviceStates(entities: [String: HAEntity], roomConfigs: [FloorPlanRoom]) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.3

            // Update device marker colors
            for (deviceId, node) in deviceNodes {
                guard let device = deviceMap[deviceId] else { continue }
                let entity = entities[device.entityId]
                if meshMode && MeshUtils.isZigbeeDevice(device.type) {
                    let lqi = MeshUtils.getLqi(entityId: device.entityId, entities: entities, zhaLqi: zhaLqi)
                    let swiftUIColor = MeshUtils.lqiToColor(lqi)
                    node.geometry?.firstMaterial?.diffuse.contents = UIColor(swiftUIColor).withAlphaComponent(0.75)
                } else {
                    let (color, opacity) = DeviceColors.uiColor(for: device.type, entity: entity)
                    node.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(opacity)
                }
            }

            // Update room floor glow
            let glows = currentFloor == 0 ? FloorPlanData.groundFloorRoomGlows : FloorPlanData.firstFloorRoomGlows
            for glow in glows {
                guard let node = roomFloorNodes[glow.id] else { continue }
                let roomConfig = roomConfigs.first { $0.id == glow.id }
                let lightEntities = roomConfig?.lightEntities ?? []
                let anyLightOn = lightEntities.contains { entities[$0]?.isOn == true }
                node.geometry?.firstMaterial?.transparency = anyLightOn ? 0.25 : 0.02
            }

            SCNTransaction.commit()
        }

    }
}
