import AVKit
import SwiftUI

extension DeviceActionSheet {
    // MARK: - Camera Content (LIVE/EVENTS + Zoom)

    var cameraContent: some View {
        VStack(spacing: 12) {
            // Mode picker
            Picker("Mode", selection: $cameraMode) {
                ForEach(CameraMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if cameraMode == .live {
                cameraLiveView
            } else {
                cameraEventsView
            }

            // Motion status + battery
            if let cam = cameraDefinition {
                cameraStatusBar(cam)
            }
        }
        .task {
            // Fetch one snapshot immediately for a fast first frame
            await loadSnapshot()
            // Activate live stream switch (triggers fresh snapshots from ring-mqtt)
            await activateLiveStream()
            // Start snapshot polling every 3s
            startSnapshotPolling()
        }
        .onDisappear {
            stopSnapshotPolling()
            deactivateLiveStream()
            videoPlayer?.pause()
            videoPlayer = nil
        }
        .onChange(of: cameraMode) { _, newMode in
            if newMode == .live {
                videoPlayer?.pause()
                videoPlayer = nil
                // Restart snapshot polling
                Task {
                    await loadSnapshot()
                    await activateLiveStream()
                    startSnapshotPolling()
                }
            } else {
                // Stop polling in events mode
                stopSnapshotPolling()
                deactivateLiveStream()
            }
        }
    }

    private var cameraLiveView: some View {
        GeometryReader { geo in
            let frameWidth = geo.size.width
            let frameHeight = geo.size.width * 9 / 16

            ZStack {
                Group {
                    if let image = snapshotImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 0)
                            .fill(Color(white: 0.15))
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "camera.example_5f7f1d8c")
                                        .font(.title)
                                        .foregroundStyle(Self.grey)
                                    Text("Loading...")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Self.grey)
                                }
                            )
                    }
                }
                .scaleEffect(zoomScale)
                .offset(zoomOffset)
            }
            .frame(width: frameWidth, height: frameHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Self.green.opacity(0.3), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Text("SECURE SNAPSHOTS · 3 SEC")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                if !cameraTimestamp.isEmpty {
                    Text(cameraTimestamp)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                }
            }
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let newScale = lastZoomScale * value
                        zoomScale = min(max(newScale, 1.0), 5.0)
                    }
                    .onEnded { _ in
                        lastZoomScale = zoomScale
                        if zoomScale <= 1.0 {
                            if reduceMotion {
                                zoomOffset = .zero
                                lastZoomOffset = .zero
                            } else {
                                withAnimation(.spring()) {
                                    zoomOffset = .zero
                                    lastZoomOffset = .zero
                                }
                            }
                        }
                    }
            )
            .simultaneousGesture(
                zoomScale > 1.0
                    ? DragGesture()
                        .onChanged { value in
                            zoomOffset = CGSize(
                                width: lastZoomOffset.width + value.translation.width,
                                height: lastZoomOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            lastZoomOffset = zoomOffset
                        }
                    : nil
            )
            .onTapGesture(count: 2) {
                if reduceMotion {
                    zoomScale = 1.0
                    lastZoomScale = 1.0
                    zoomOffset = .zero
                    lastZoomOffset = .zero
                } else {
                    withAnimation(.spring()) {
                        zoomScale = 1.0
                        lastZoomScale = 1.0
                        zoomOffset = .zero
                        lastZoomOffset = .zero
                    }
                }
            }
            // Zoom +/- buttons for accessibility (#34)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Button {
                        let newScale = max(zoomScale - 0.5, 1.0)
                        if reduceMotion {
                            zoomScale = newScale
                            lastZoomScale = newScale
                            if newScale <= 1.0 {
                                zoomOffset = .zero
                                lastZoomOffset = .zero
                            }
                        } else {
                            withAnimation(.spring()) {
                                zoomScale = newScale
                                lastZoomScale = newScale
                                if newScale <= 1.0 {
                                    zoomOffset = .zero
                                    lastZoomOffset = .zero
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Zoom out")
                    .disabled(zoomScale <= 1.0)

                    Button {
                        let newScale = min(zoomScale + 0.5, 5.0)
                        if reduceMotion {
                            zoomScale = newScale
                            lastZoomScale = newScale
                        } else {
                            withAnimation(.spring()) {
                                zoomScale = newScale
                                lastZoomScale = newScale
                            }
                        }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Zoom in")
                    .disabled(zoomScale >= 5.0)
                }
                .padding(8)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var cameraEventsView: some View {
        VStack(spacing: 12) {
            let options = filteredEventOptions

            if options.isEmpty {
                Text("No events available")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .padding()
            } else {
                // Video player
                if let player = videoPlayer {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Self.green.opacity(0.3), lineWidth: 1)
                        )
                } else if eventLoading {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.15))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(ProgressView().tint(Self.green))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.15))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(
                            Text(
                                eventPlaybackUnavailable
                                    ? "Recorded video unavailable in secure mode"
                                    : "Select an event"
                            )
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Self.grey)
                        )
                }

                // Navigation
                HStack {
                    Button {
                        navigateEvent(direction: -1)
                    } label: {
                        Image(systemName: "chevron.left.2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(eventIndex > 0 ? Self.green : Self.grey)
                    }
                    .disabled(eventIndex <= 0)

                    Spacer()

                    VStack(spacing: 2) {
                        Text(options.indices.contains(eventIndex) ? options[eventIndex] : "")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(eventIndex + 1) / \(options.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Self.grey)
                    }

                    Spacer()

                    Button {
                        navigateEvent(direction: 1)
                    } label: {
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(eventIndex < options.count - 1 ? Self.green : Self.grey)
                    }
                    .disabled(eventIndex >= options.count - 1)
                }
            }
        }
        .onAppear {
            // Auto-select first event when events view mounts
            let options = filteredEventOptions
            if !options.isEmpty {
                eventIndex = 0
                selectEvent(options[0])
            }
        }
    }

    private func cameraStatusBar(_ cam: FloorPlanData.CameraDefinition) -> some View {
        VStack(spacing: 8) {
            let motionEntity = viewModel.haClient.entities[cam.motionEntityId]
            let motionDetected = motionEntity?.isOn == true

            HStack(spacing: 8) {
                Circle()
                    .fill(motionDetected ? Color.hackerAmber : Self.green)
                    .frame(width: 10, height: 10)

                Text(motionDetected ? "MOTION DETECTED" : "CLEAR")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(motionDetected ? Color.hackerAmber : Self.green)

                Spacer()
            }

            // Last motion time
            if let lastChanged = motionEntity?.lastChanged {
                let timeStr = formatISOTime(lastChanged)
                statusRow("LAST MOTION", value: timeStr, color: Self.grey)
            }

            // Battery level (from the camera entity or a related battery sensor)
            if let battery = entity?.batteryLevel {
                statusRow(
                    "BATTERY", value: "\(battery)%",
                    color: battery > 20 ? Self.green : Self.red)
            }
        }
    }

    // MARK: - Camera Helpers

    private var filteredEventOptions: [String] {
        guard let cam = cameraDefinition else { return [] }
        let selectEntity = viewModel.haClient.entities[cam.eventSelectId]
        let options = selectEntity?.selectOptions ?? []
        return options.filter { option in
            let lower = option.lowercased()
            return !lower.contains("transcoded") && !lower.contains("on-demand")
        }.reversed()  // newest first
    }

    private func navigateEvent(direction: Int) {
        let options = filteredEventOptions
        let newIndex = eventIndex + direction
        guard options.indices.contains(newIndex) else { return }
        HapticManager.selection()
        eventIndex = newIndex
        selectEvent(options[newIndex])
    }

    private func selectEvent(_ option: String) {
        guard let cam = cameraDefinition else { return }
        eventLoading = true
        eventPlaybackUnavailable = false
        videoPlayer?.pause()
        videoPlayer = nil

        // Stop snapshot polling during event mode
        stopSnapshotPolling()

        Task {
            videoPlayer = await viewModel.fetchDoorVideo(eventSelectId: cam.eventSelectId, option: option)
            eventPlaybackUnavailable = videoPlayer == nil
            eventLoading = false
        }
    }

    @MainActor
    private func loadSnapshot() async {
        guard let cam = cameraDefinition else { return }
        // Use pre-fetched cache for instant first load
        if snapshotImage == nil, let cached = viewModel.haClient.cachedImage(forKey: NSString(string: cam.entityId)) {
            snapshotImage = cached
        }
        if let refreshed = await viewModel.haClient.fetchSnapshot(entityId: cam.entityId) {
            snapshotImage = refreshed
            // Use entity timestamp attribute (actual capture time) if available
            if let entity = viewModel.haClient.entities[cam.entityId],
                let ts = entity.attributes["timestamp"]
            {
                switch ts {
                case .int(let v):
                    cameraTimestamp = ISODateParser.timeWithSeconds(
                        from: Date(timeIntervalSince1970: TimeInterval(v))
                    )
                case .double(let v):
                    cameraTimestamp = ISODateParser.timeWithSeconds(
                        from: Date(timeIntervalSince1970: v)
                    )
                default:
                    cameraTimestamp = ISODateParser.timeWithSeconds(from: Date())
                }
            } else {
                cameraTimestamp = ISODateParser.timeWithSeconds(from: Date())
            }
        }
    }

    // MARK: - Snapshot Polling

    /// Derive the live stream switch entity ID from the camera entity.
    /// camera.example_d1e26056 → switch.example_24de33ac
    private var liveStreamSwitchId: String? {
        guard let cam = cameraDefinition else { return nil }
        let baseName = cam.entityId
            .replacingOccurrences(of: "camera.", with: "")
            .replacingOccurrences(of: "_snapshot", with: "")
        return "switch.\(baseName)_live_stream"
    }

    private func activateLiveStream() async {
        guard let switchId = liveStreamSwitchId else { return }
        _ = await callService(
            domain: "switch",
            service: "turn_on",
            data: ["entity_id": switchId]
        )
    }

    private func deactivateLiveStream() {
        guard let switchId = liveStreamSwitchId else { return }
        Task {
            _ = await callService(
                domain: "switch",
                service: "turn_off",
                data: ["entity_id": switchId]
            )
        }
    }

    private func startSnapshotPolling() {
        stopSnapshotPolling()
        snapshotPollingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await loadSnapshot()
            }
        }
    }

    private func stopSnapshotPolling() {
        snapshotPollingTask?.cancel()
        snapshotPollingTask = nil
    }

    private func formatISOTime(_ iso: String) -> String {
        guard let date = ISODateParser.parse(iso) else { return iso }
        return ISODateParser.timeWithSeconds(from: date)
    }
}
