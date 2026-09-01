import Combine
import SwiftUI

/// Fullscreen floor plan with 2D/3D toggle, floor picker, and device action sheet.
struct FloorPlanFullscreenView: View {
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    @State private var showSitrep = false
    @State private var meshMode = false

    /// Activity trail service for motion-based trail rendering.
    @State private var activityTrailService = ActivityTrailService()

    /// Ripple animation phase (0.0 to 1.0, cycles every 2 seconds while motion is active).
    @State private var ripplePhase: CGFloat = 0

    private static let green = Color.hackerGreen
    private static let grey = Color.hackerGrey

    /// Whether any camera currently has motion detected (used to drive ripple animation).
    private var anyCameraMotion: Bool {
        FloorPlanData.cameras.contains { camera in
            viewModel.haClient.entities[camera.motionEntityId]?.isOn == true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
                .accessibilityLabel("Dismiss")

                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    if !viewModel.isMockData {
                        Button {
                            HapticManager.selection()
                            showSitrep = true
                        } label: {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 16))
                                .foregroundStyle(Self.green)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Situation report")
                    }

                    if !viewModel.isMockData {
                        Button {
                            HapticManager.selection()
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                appState.showingAssistantChat = true
                            }
                        } label: {
                            Image(systemName: "bubble.left.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Self.green)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Ask Bismarck")
                    }

                    if !viewModel.isMockData {
                        Button {
                            HapticManager.selection()
                            meshMode.toggle()
                        } label: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 16))
                                .foregroundStyle(meshMode ? Self.green : Self.grey)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Mesh view")
                    }
                }

                Spacer()

                Picker("Mode", selection: $viewModel.viewMode) {
                    ForEach(FloorPlanViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Floor picker
            Picker("Floor", selection: $viewModel.selectedFloor) {
                Text("Ground").tag(0)
                Text("First").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            // Mesh mode legend
            if meshMode {
                HStack(spacing: 16) {
                    meshLegendDot(color: .hackerGreen, label: "STRONG")
                    meshLegendDot(color: .hackerOrange, label: "MEDIUM")
                    meshLegendDot(color: .meshWeak, label: "WEAK")
                    meshLegendDot(color: .hackerGrey, label: "NO DATA")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(white: 0.06))
            }

            // Main content
            Group {
                if viewModel.viewMode == .threeD {
                    FloorPlan3DView(
                        floor: viewModel.selectedFloor,
                        devices: viewModel.floorPlanDevices,
                        entities: viewModel.haClient.entities,
                        roomConfigs: viewModel.floorPlanRooms,
                        meshMode: meshMode,
                        isDemoMode: viewModel.isMockData,
                        zhaLqi: viewModel.haClient.zhaLqi,
                        onDeviceTap: { device in
                            viewModel.selectedDevice = device
                        }
                    )
                } else {
                    FloorPlanView(
                        floor: viewModel.selectedFloor,
                        devices: viewModel.floorPlanDevices,
                        entities: viewModel.haClient.entities,
                        roomConfigs: viewModel.floorPlanRooms,
                        meshMode: meshMode,
                        isDemoMode: viewModel.isMockData,
                        zhaLqi: viewModel.haClient.zhaLqi,
                        activityTrails: activityTrailService.trails,
                        onDeviceTap: { device in
                            viewModel.selectedDevice = device
                        },
                        onCameraTap: { camera in
                            viewModel.selectedDevice = cameraToDevice(camera)
                        },
                        onRoomTap: { room in
                            handleRoomTap(room)
                        },
                        ripplePhase: ripplePhase
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 8)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .onAppear {
            activityTrailService.startMonitoring()
        }
        .onChange(of: anyCameraMotion, initial: true) { _, isActive in
            setRippleAnimationActive(isActive)
        }
        .onDisappear {
            activityTrailService.stopMonitoring()
            setRippleAnimationActive(false)
        }
        .onReceive(viewModel.haClient.$entities) { newEntities in
            activityTrailService.update(
                entities: newEntities,
                devices: viewModel.floorPlanDevices
            )
        }
        .sheet(item: $viewModel.selectedDevice) { device in
            if meshMode && MeshUtils.isZigbeeDevice(device.type) {
                meshInfoSheet(device: device)
                    .presentationDetents([.fraction(0.3)])
                    .presentationDragIndicator(.visible)
                    .preferredColorScheme(.dark)
            } else {
                DeviceActionSheet(
                    device: device,
                    viewModel: viewModel
                )
                .presentationDetents([sheetDetent(for: device.type)])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $showSitrep) {
            SitrepView(entities: viewModel.haClient.entities)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Ripple Animation

    @State private var rippleTimer: Timer?

    private func setRippleAnimationActive(_ isActive: Bool) {
        rippleTimer?.invalidate()
        rippleTimer = nil
        guard isActive else { return }
        // Cycle through 0.0 to 1.0 every 2 seconds, updating at ~30fps only
        // while a camera is actively reporting motion.
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in
                ripplePhase = (ripplePhase + CGFloat(1.0 / 30.0) / 2.0)
                    .truncatingRemainder(dividingBy: 1.0)
            }
        }
        rippleTimer = timer
    }

    // MARK: - Room Tap Handler

    private func handleRoomTap(_ room: FloorPlanRoom) {
        let lightEntities = room.lightEntities
        guard !lightEntities.isEmpty else { return }

        // Check if any light in the room is currently on
        let anyOn = lightEntities.contains { entityId in
            viewModel.haClient.entities[entityId]?.isOn == true
        }

        // If any are on, turn all off; otherwise turn all on
        let service = anyOn ? "turn_off" : "turn_on"

        Task {
            for entityId in lightEntities {
                await viewModel.performAction(
                    domain: "light",
                    service: service,
                    data: ["entity_id": entityId]
                ) {
                    viewModel.haClient.updateEntityOptimistically(
                        entityId,
                        state: anyOn ? "off" : "on"
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private func cameraToDevice(_ camera: FloorPlanData.CameraDefinition) -> FloorPlanDevice {
        FloorPlanDevice(
            id: camera.id,
            entityId: camera.entityId,
            type: "camera",
            floor: 0,
            x: camera.cx,
            y: camera.cy,
            room: "",
            label: camera.label
        )
    }

    private func meshLegendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private func meshInfoSheet(device: FloorPlanDevice) -> some View {
        let info = MeshUtils.meshInfo(
            type: device.type,
            entityId: device.entityId,
            entities: viewModel.haClient.entities,
            zhaLqi: viewModel.haClient.zhaLqi
        )

        return VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.gray.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            HStack(spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(info.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.label)
                        .font(.system(.headline, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("MESH STATUS")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)
                }
                Spacer()
            }
            .padding(.horizontal)

            Divider().background(Self.green.opacity(0.2))

            VStack(spacing: 12) {
                HStack {
                    Text("Signal")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Self.grey)
                    Spacer()
                    Text(info.signalLabel)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(info.color)
                }

                HStack {
                    Text("LQI")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Self.grey)
                    Spacer()
                    Text(info.lqi.map { "\($0)/255" } ?? "N/A")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(info.lqi != nil ? .white : Self.grey)
                }

                HStack {
                    Text("Role")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Self.grey)
                    Spacer()
                    Text(info.isRouter ? "ROUTER" : "END DEVICE")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(info.isRouter ? Self.green : Self.grey)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }

    private func sheetDetent(for deviceType: String) -> PresentationDetent {
        switch deviceType {
        case "trv": return .fraction(0.75)
        case "speaker": return .fraction(0.85)
        case "camera": return .fraction(0.7)
        default: return .fraction(0.4)
        }
    }
}
