import SwiftUI

/// Native SwiftUI floor plan rendered with Canvas.
/// Maps SVG viewBox (0 0 900 820) coordinates to screen via uniform scale factor.
struct FloorPlanView: View {
    let floor: Int  // 0 = ground, 1 = first
    let devices: [FloorPlanDevice]
    let entities: [String: HAEntity]
    let roomConfigs: [FloorPlanRoom]
    var meshMode: Bool = false
    var isDemoMode: Bool = false
    var zhaLqi: [String: Int] = [:]
    var activityTrails: [ActivityTrailEntry] = []
    var onDeviceTap: ((FloorPlanDevice) -> Void)?
    var onCameraTap: ((FloorPlanData.CameraDefinition) -> Void)?
    var onRoomTap: ((FloorPlanRoom) -> Void)?

    /// Animation phase for camera motion ripple (0.0 to 1.0, cycles continuously).
    var ripplePhase: CGFloat = 0

    // Colors matching React dashboard exactly
    private static let wallColor = Color.hackerGreen
    private static let externalDoorColor = Color.externalDoor
    private static let labelColor = Color.hackerGrey

    // Activity trail colors
    private static let trailColorOrange = Color(red: 1.0, green: 0.647, blue: 0) // #FFA500
    private static let trailColorGold = Color(red: 1.0, green: 0.843, blue: 0)   // #FFD700

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / FloorPlanData.viewBoxWidth,
                geometry.size.height / FloorPlanData.viewBoxHeight
            )
            let offsetX = (geometry.size.width - FloorPlanData.viewBoxWidth * scale) / 2
            let offsetY = (geometry.size.height - FloorPlanData.viewBoxHeight * scale) / 2

            ZStack {
                Canvas { context, _ in
                    // Translate to center the floor plan
                    context.translateBy(x: offsetX, y: offsetY)

                    drawGrid(context: &context, scale: scale)
                    drawRoomGlows(context: &context, scale: scale)
                    drawWalls(context: &context, scale: scale)
                    drawPartitionWalls(context: &context, scale: scale)
                    drawStairs(context: &context, scale: scale)
                    drawDoors(context: &context, scale: scale)
                    drawCornerBrackets(context: &context, scale: scale)
                    drawLabels(context: &context, scale: scale)
                    drawActivityTrails(context: &context, scale: scale)
                    drawDevices(context: &context, scale: scale)
                    drawCameras(context: &context, scale: scale)
                }

                // Invisible room tap targets (behind device tap targets)
                if onRoomTap != nil {
                    let floorRooms = roomConfigs.filter { $0.floor == floor && !$0.lightEntities.isEmpty }
                    ForEach(floorRooms) { room in
                        roomTapTarget(room: room, scale: scale, offsetX: offsetX, offsetY: offsetY)
                    }
                }

                // Invisible tap targets over each device
                if onDeviceTap != nil {
                    let floorDevices = devices.filter { $0.floor == floor }
                    ForEach(floorDevices) { device in
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .position(
                                x: offsetX + device.x * scale,
                                y: offsetY + device.y * scale
                            )
                            .onTapGesture {
                                HapticManager.light()
                                onDeviceTap?(device)
                            }
                    }
                }

                // Camera tap targets (ground floor only)
                if floor == 0, onCameraTap != nil {
                    ForEach(FloorPlanData.cameras, id: \.id) { camera in
                        Color.clear
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .position(
                                x: offsetX + camera.cx * scale,
                                y: offsetY + camera.cy * scale
                            )
                            .onTapGesture {
                                HapticManager.light()
                                onCameraTap?(camera)
                            }
                    }
                }
            }
            .background(.black)
        }
        .aspectRatio(FloorPlanData.viewBoxWidth / FloorPlanData.viewBoxHeight, contentMode: .fit)
        // Floor plan accessibility (#34): expose device positions as accessible elements
        .accessibilityElement(children: .contain)
        .accessibilityChildren {
            let floorDevices = devices.filter { $0.floor == floor }
            ForEach(floorDevices) { device in
                let entity = entities[device.entityId]
                let stateLabel = entity?.state ?? "unknown"
                Button(device.label) {
                    onDeviceTap?(device)
                }
                .accessibilityLabel("\(device.label), \(stateLabel)")
                .accessibilityHint("Double tap to control")
            }
            if floor == 0 {
                ForEach(FloorPlanData.cameras, id: \.id) { camera in
                    Button(camera.label) {
                        onCameraTap?(camera)
                    }
                    .accessibilityLabel("\(camera.label), camera")
                    .accessibilityHint("Double tap to view")
                }
            }
        }
    }

    // MARK: - Room Tap Targets

    @ViewBuilder
    private func roomTapTarget(room: FloorPlanRoom, scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> some View {
        let bounds = room.bounds.cgRect
        Color.clear
            .frame(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            .contentShape(Rectangle())
            .position(
                x: offsetX + (bounds.origin.x + bounds.width / 2) * scale,
                y: offsetY + (bounds.origin.y + bounds.height / 2) * scale
            )
            .onTapGesture {
                HapticManager.medium()
                onRoomTap?(room)
            }
    }

    // MARK: - Grid

    private func drawGrid(context: inout GraphicsContext, scale: CGFloat) {
        let gridSpacing: CGFloat = 30 * scale
        let gridColor = Self.wallColor.opacity(0.03)
        let maxX = FloorPlanData.viewBoxWidth * scale
        let maxY = FloorPlanData.viewBoxHeight * scale

        var gridPath = Path()
        var x: CGFloat = 0
        while x <= maxX {
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: maxY))
            x += gridSpacing
        }
        var y: CGFloat = 0
        while y <= maxY {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: maxX, y: y))
            y += gridSpacing
        }
        context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5 * scale)
    }

    // MARK: - Room Glows

    private func drawRoomGlows(context: inout GraphicsContext, scale: CGFloat) {
        let glows = floor == 0 ? FloorPlanData.groundFloorRoomGlows : FloorPlanData.firstFloorRoomGlows

        for glow in glows {
            // Check if any light in this room is on
            let roomConfig = roomConfigs.first { $0.id == glow.id }
            let lightEntities = roomConfig?.lightEntities ?? []
            let anyLightOn = lightEntities.contains { entityId in
                entities[entityId]?.isOn == true
            }

            guard anyLightOn else { continue }

            let path: Path
            if let polygon = glow.polygon {
                path = polygonPath(polygon, scale: scale)
            } else {
                path = Path(scaledRect(glow.bounds, scale: scale))
            }

            // Radial gradient fill matching React: center #39ff6e 0.20 -> 70% 0.06 -> 100% 0
            let center = CGPoint(
                x: glow.bounds.midX * scale,
                y: glow.bounds.midY * scale
            )
            let radius = max(glow.bounds.width, glow.bounds.height) * scale / 2
            context.drawLayer { layerContext in
                layerContext.clip(to: path)
                layerContext.fill(
                    Path(CGRect(x: 0, y: 0,
                                width: FloorPlanData.viewBoxWidth * scale,
                                height: FloorPlanData.viewBoxHeight * scale)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Self.wallColor.opacity(0.20), location: 0),
                            .init(color: Self.wallColor.opacity(0.06), location: 0.7),
                            .init(color: Self.wallColor.opacity(0), location: 1.0),
                        ]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }
    }

    // MARK: - Walls

    private func drawWalls(context: inout GraphicsContext, scale: CGFloat) {
        let walls = floor == 0 ? FloorPlanData.groundFloorWalls : FloorPlanData.firstFloorWalls

        var wallPath = Path()
        for (x1, y1, x2, y2) in walls {
            wallPath.move(to: CGPoint(x: x1 * scale, y: y1 * scale))
            wallPath.addLine(to: CGPoint(x: x2 * scale, y: y2 * scale))
        }

        // Wall glow (blur effect simulated by drawing thick then thin)
        context.stroke(wallPath, with: .color(Self.wallColor.opacity(0.3)), lineWidth: 4 * scale)
        context.stroke(wallPath, with: .color(Self.wallColor.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round))
    }

    private func drawPartitionWalls(context: inout GraphicsContext, scale: CGFloat) {
        let partitions = floor == 0 ? FloorPlanData.groundFloorPartitionWalls : FloorPlanData.firstFloorPartitionWalls

        var partPath = Path()
        for (x1, y1, x2, y2) in partitions {
            partPath.move(to: CGPoint(x: x1 * scale, y: y1 * scale))
            partPath.addLine(to: CGPoint(x: x2 * scale, y: y2 * scale))
        }

        context.stroke(partPath, with: .color(Self.wallColor.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1.2 * scale, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Stairs

    private func drawStairs(context: inout GraphicsContext, scale: CGFloat) {
        if floor == 0 {
            // Dashed rectangle
            let rect = scaledRect(FloorPlanData.groundFloorStairsRect, scale: scale)
            var rectPath = Path()
            rectPath.addRect(rect)
            context.stroke(rectPath, with: .color(Self.wallColor.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1.0 * scale, dash: [4 * scale, 3 * scale]))

            // Tread lines
            var treadPath = Path()
            for y in FloorPlanData.groundFloorStairsTreads {
                treadPath.move(to: CGPoint(x: FloorPlanData.stairsTreadX1 * scale, y: y * scale))
                treadPath.addLine(to: CGPoint(x: FloorPlanData.stairsTreadX2 * scale, y: y * scale))
            }
            context.stroke(treadPath, with: .color(Self.wallColor.opacity(0.08)),
                           style: StrokeStyle(lineWidth: 0.5 * scale))
        } else {
            // First floor: dashed bottom line
            let (p1, p2) = FloorPlanData.firstFloorStairsLine
            var linePath = Path()
            linePath.move(to: CGPoint(x: p1.x * scale, y: p1.y * scale))
            linePath.addLine(to: CGPoint(x: p2.x * scale, y: p2.y * scale))
            context.stroke(linePath, with: .color(Self.wallColor.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1.0 * scale, dash: [4 * scale, 3 * scale]))

            // Tread lines
            var treadPath = Path()
            for y in FloorPlanData.firstFloorStairsTreads {
                treadPath.move(to: CGPoint(x: FloorPlanData.stairsTreadX1 * scale, y: y * scale))
                treadPath.addLine(to: CGPoint(x: FloorPlanData.stairsTreadX2 * scale, y: y * scale))
            }
            context.stroke(treadPath, with: .color(Self.wallColor.opacity(0.08)),
                           style: StrokeStyle(lineWidth: 0.5 * scale))
        }
    }

    // MARK: - Doors

    private func drawDoors(context: inout GraphicsContext, scale: CGFloat) {
        // External doors (red) -- ground floor only
        if floor == 0 {
            for doorRect in FloorPlanData.groundFloorExternalDoors {
                let rect = scaledRect(doorRect, scale: scale)
                context.fill(Path(rect), with: .color(Self.externalDoorColor.opacity(0.7)))
            }
        }

        // Internal doors (green, faint)
        let internalDoors = floor == 0 ? FloorPlanData.groundFloorInternalDoors : FloorPlanData.firstFloorInternalDoors
        for doorRect in internalDoors {
            let rect = scaledRect(doorRect, scale: scale)
            context.fill(Path(rect), with: .color(Self.wallColor.opacity(0.2)))
        }
    }

    // MARK: - Corner Brackets

    private func drawCornerBrackets(context: inout GraphicsContext, scale: CGFloat) {
        for bracket in FloorPlanData.cornerBrackets {
            guard bracket.points.count == 3 else { continue }
            var path = Path()
            path.move(to: CGPoint(x: bracket.points[0].x * scale, y: bracket.points[0].y * scale))
            path.addLine(to: CGPoint(x: bracket.points[1].x * scale, y: bracket.points[1].y * scale))
            path.addLine(to: CGPoint(x: bracket.points[2].x * scale, y: bracket.points[2].y * scale))
            context.stroke(path, with: .color(Self.wallColor.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 0.5 * scale))
        }
    }

    // MARK: - Labels

    private func drawLabels(context: inout GraphicsContext, scale: CGFloat) {
        let labels = floor == 0 ? FloorPlanData.groundFloorLabels : FloorPlanData.firstFloorLabels

        for label in labels {
            let displayText = FloorPlanData.demoLabel(label.text, isDemoMode: isDemoMode)
            let lines = displayText.split(separator: "\n", omittingEmptySubsequences: false)
            let fontSize = label.fontSize * scale
            let lineHeight = fontSize * 1.4

            for (i, line) in lines.enumerated() {
                let yOffset = CGFloat(i) * lineHeight - CGFloat(lines.count - 1) * lineHeight / 2

                let text = Text(String(line))
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(Self.labelColor.opacity(label.opacity))

                let resolved = context.resolve(text)
                let textSize = resolved.measure(in: CGSize(width: 300 * scale, height: 100 * scale))

                context.draw(resolved, at: CGPoint(
                    x: label.position.x * scale - textSize.width / 2,
                    y: label.position.y * scale + yOffset - textSize.height / 2
                ), anchor: .topLeading)
            }
        }
    }

    // MARK: - Activity Trails

    private func drawActivityTrails(context: inout GraphicsContext, scale: CGFloat) {
        let floorTrails = activityTrails.filter { $0.floor == floor }
        guard !floorTrails.isEmpty else { return }

        for trail in floorTrails {
            let center = CGPoint(x: trail.x * scale, y: trail.y * scale)
            let trailOpacity = trail.opacity
            guard trailOpacity > 0 else { continue }

            let radius: CGFloat = 7 * scale

            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))

            // Gradient from orange (#FFA500) to gold (#FFD700), blended based on age
            // Younger trails are more orange, older trails fade toward gold
            let blendFactor = 1.0 - trailOpacity // 0 = new (orange), 1 = old (gold)
            let trailColor = blendColor(
                from: Self.trailColorOrange,
                to: Self.trailColorGold,
                factor: blendFactor
            )

            context.fill(circle, with: .color(trailColor.opacity(trailOpacity)))

            // Add a subtle glow around the trail dot
            let glowRadius: CGFloat = 12 * scale
            let glowCircle = Path(ellipseIn: CGRect(
                x: center.x - glowRadius, y: center.y - glowRadius,
                width: glowRadius * 2, height: glowRadius * 2
            ))
            context.fill(glowCircle, with: .color(trailColor.opacity(trailOpacity * 0.2)))
        }
    }

    /// Blend between two colors by a factor (0.0 = from, 1.0 = to).
    private func blendColor(from: Color, to: Color, factor: Double) -> Color {
        // Use a simple linear interpolation via resolved colors
        let f = min(1, max(0, factor))
        // Since we know these are fixed colors, use a gradient approach
        // For Canvas drawing, we just pick one based on threshold
        return f < 0.5 ? from : to
    }

    // MARK: - Devices

    private func drawDevices(context: inout GraphicsContext, scale: CGFloat) {
        let floorDevices = devices.filter { $0.floor == floor }

        for device in floorDevices {
            let center = CGPoint(x: device.x * scale, y: device.y * scale)
            let entity = entities[device.entityId]

            let (fillColor, fillOpacity): (Color, Double)
            if meshMode && MeshUtils.isZigbeeDevice(device.type) {
                let info = MeshUtils.meshInfo(type: device.type, entityId: device.entityId, entities: entities, zhaLqi: zhaLqi)
                fillColor = info.color
                fillOpacity = 0.75
            } else {
                (fillColor, fillOpacity) = DeviceColors.color(for: device.type, entity: entity)
            }

            // Circle for all device types
            let radius: CGFloat = 14 * scale
            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            context.fill(circle, with: .color(fillColor.opacity(fillOpacity)))

            // TRV temperature label below dot
            if device.type == "trv", let entity = entity {
                let temp = entity.currentTemperature
                let hvacAction = entity.hvacAction ?? "off"
                if let temp = temp {
                    let trvColor: Color = {
                        switch hvacAction {
                        case "heating": return .hackerOrange
                        case "idle": return Self.wallColor
                        default: return Self.labelColor
                        }
                    }()
                    let trvOpacity: Double = hvacAction == "off" ? 0.4 : 0.8
                    let tempText = Text(String(format: "%.0f\u{00B0}", temp))
                        .font(.system(size: 8 * scale, design: .monospaced))
                        .foregroundColor(trvColor.opacity(trvOpacity))
                    let resolved = context.resolve(tempText)
                    context.draw(resolved, at: CGPoint(x: center.x, y: center.y + 22 * scale), anchor: .top)
                }
            }
        }
    }

    // MARK: - Cameras

    private func drawCameras(context: inout GraphicsContext, scale: CGFloat) {
        guard floor == 0 else { return }

        for camera in FloorPlanData.cameras {
            let center = CGPoint(x: camera.cx * scale, y: camera.cy * scale)
            let motionEntity = entities[camera.motionEntityId]
            let motionDetected = motionEntity?.isOn == true

            let (fillColor, fillOpacity) = DeviceColors.color(for: "camera", entity: entities[camera.entityId])

            // Same filled circle as all other devices
            let radius: CGFloat = 14 * scale
            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            context.fill(circle, with: .color(fillColor.opacity(fillOpacity)))

            // Motion glow ring (when motion detected) -- existing behavior
            if motionDetected {
                let glowRadius: CGFloat = 18 * scale
                let glowCircle = Path(ellipseIn: CGRect(
                    x: center.x - glowRadius, y: center.y - glowRadius,
                    width: glowRadius * 2, height: glowRadius * 2
                ))
                context.stroke(glowCircle, with: .color(Color.hackerAmber.opacity(0.4)), lineWidth: 1.5 * scale)

                // Camera motion ripple: 3 concentric expanding/pulsing circles
                drawCameraRipple(context: &context, center: center, scale: scale)
            }
        }
    }

    /// Draw 3 concentric expanding ripple circles around a camera with active motion.
    /// Each ring is offset by 1/3 of the animation cycle so they stagger.
    private func drawCameraRipple(context: inout GraphicsContext, center: CGPoint, scale: CGFloat) {
        for ringIndex in 0..<3 {
            // Offset each ring by 1/3 of the cycle
            let ringOffset = CGFloat(ringIndex) / 3.0
            let phase = (ripplePhase + ringOffset).truncatingRemainder(dividingBy: 1.0)

            // Ring 1: 10->20, Ring 2: 15->30, Ring 3: 20->40 (in viewBox units)
            let minRadius: CGFloat = CGFloat(10 + ringIndex * 5)
            let maxRadius: CGFloat = CGFloat(20 + ringIndex * 10)
            let currentRadius = (minRadius + (maxRadius - minRadius) * phase) * scale

            // Opacity fades as the ring expands
            let baseOpacity: Double = 0.5 - Double(ringIndex) * 0.12
            let fadeOpacity = baseOpacity * Double(1.0 - phase)

            guard fadeOpacity > 0.01 else { continue }

            let rippleCircle = Path(ellipseIn: CGRect(
                x: center.x - currentRadius, y: center.y - currentRadius,
                width: currentRadius * 2, height: currentRadius * 2
            ))

            context.stroke(
                rippleCircle,
                with: .color(Color.hackerAmber.opacity(fadeOpacity)),
                lineWidth: 1.2 * scale
            )
        }
    }

    // MARK: - Helpers

    private func scaledRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: rect.origin.x * scale, y: rect.origin.y * scale,
               width: rect.size.width * scale, height: rect.size.height * scale)
    }

    private func polygonPath(_ points: [CGPoint], scale: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
        }
        path.closeSubpath()
        return path
    }
}
