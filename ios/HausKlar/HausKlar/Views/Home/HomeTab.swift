import Charts
import SwiftUI

private struct RoomTemperatureReading: Identifiable {
    let id: String
    let name: String
    let value: Double?
    let dewPoint: Double?
    let temperatureEntityId: String?
    let thermostat: HomeViewModel.HeatingRoom?
    let isHeating: Bool
}

/// Exception- and favourite-first House screen backed by the server capability manifest.
/// Live, last-known, unavailable, unconfigured, and explicit demo remain distinct truth states.
struct HomeTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTemperatureRoom: RoomTemperatureReading?
    @State private var showingFavourites = false
    @State private var showingBroadAction = false
    @State private var showingModePicker = false
    @State private var pendingMode: String?
    @State private var pendingBroadAction: HomeBroadActionChoice?
    @State private var pendingScene: HomeManifestEntityDTO?
    @State private var fullControlsExpanded = false
    @State private var advancedExpanded = false
    @State private var boostingHotWater = false

    private var isAdmin: Bool {
        appState.currentUser?.role.lowercased() == "admin"
    }

    var body: some View {
        Group {
            switch viewModel.presentationState {
            case .loading:
                ProgressView("Loading house status…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notConfigured:
                notConfiguredView
            case .unavailable:
                unavailableView
            case .live, .lastKnown, .demo:
                connectedView
            }
        }
        .navigationTitle("House")
        .task {
            await viewModel.startMonitoring()
        }
        .onDisappear {
            viewModel.stopMonitoring()
        }
        .onChange(of: appState.selectedTab) { _, newValue in
            if newValue == .family || newValue == .house {
                viewModel.resumePolling()
            } else {
                viewModel.pausePolling()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.scenePhase = newPhase
            switch newPhase {
            case .background:
                viewModel.pausePolling()
            case .active:
                viewModel.resumePolling()
            default:
                break
            }
        }
        .sheet(item: $selectedTemperatureRoom) { room in
            RoomTemperatureControlSheet(room: room, viewModel: viewModel)
        }
        .sheet(isPresented: $showingFavourites) {
            if let manifest = viewModel.manifest {
                HomeFavouritesSheet(manifest: manifest) { entityIds in
                    await viewModel.saveFavourites(entityIds)
                }
            }
        }
        .sheet(isPresented: $showingBroadAction) {
            if let manifest = viewModel.manifest {
                HomeBroadActionSheet(manifest: manifest) { choice in
                    pendingBroadAction = choice
                }
            }
        }
        .sheet(isPresented: $showingModePicker) {
            if let selector = viewModel.manifest?.modeSelector {
                HomeModePicker(selector: selector) { option in
                    pendingMode = option
                }
            }
        }
        .alert(
            "Change house mode to \(pendingMode ?? "this mode")?",
            isPresented: Binding(
                get: { pendingMode != nil },
                set: { if !$0 { pendingMode = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingMode = nil }
            Button("Use \(pendingMode ?? "mode")") {
                guard let option = pendingMode else { return }
                pendingMode = nil
                Task {
                    await viewModel.setHouseMode(option)
                    HapticManager.medium()
                }
            }
        } message: {
            Text("Home Assistant may run automations attached to this mode. HausKlar will send only the exact mode you chose.")
        }
        .alert(
            broadAlertTitle,
            isPresented: Binding(
                get: { pendingBroadAction != nil },
                set: { if !$0 { pendingBroadAction = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingBroadAction = nil }
            Button(broadConfirmLabel) {
                guard let choice = pendingBroadAction else { return }
                pendingBroadAction = nil
                Task {
                    _ = await viewModel.performBroadAction(choice)
                    HapticManager.medium()
                }
            }
        } message: {
            Text(broadAlertMessage)
        }
        .alert(
            "Run \(pendingScene?.name ?? "this scene")?",
            isPresented: Binding(
                get: { pendingScene != nil },
                set: { if !$0 { pendingScene = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingScene = nil }
            Button("Run scene") {
                guard let scene = pendingScene else { return }
                pendingScene = nil
                Task {
                    await viewModel.activateScene(scene.entityId)
                    HapticManager.medium()
                }
            }
        } message: {
            Text("Scenes can change several devices. HausKlar will run only this explicitly approved Home Assistant scene.")
        }
    }

    private var notConfiguredView: some View {
        ContentUnavailableView {
            Label("House not connected", systemImage: "house.circle")
        } description: {
            Text(
                isAdmin
                    ? "Connect Home Assistant through the private HausKlar server in Settings."
                    : "Ask your family admin to connect Home Assistant in Settings."
            )
        } actions: {
            if isAdmin {
                Button("Open Settings") { appState.showingSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView {
            Label("House status unavailable", systemImage: "house.circle")
        } description: {
            Text("HausKlar can’t reach the household connection. No sample state has been substituted.")
        } actions: {
            Button("Try Again") { Task { await viewModel.retry() } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var connectedView: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                if viewModel.isDemoMode {
                    demoModeBanner
                } else if viewModel.presentationState == .lastKnown {
                    lastKnownBanner
                }

                if let error = viewModel.errorMessage {
                    inlineError(error)
                }

                if let manifest = viewModel.manifest {
                    sitrepSection
                    houseGlanceSection(manifest)
                    fullControlsSection(manifest)
                } else if viewModel.isDemoMode {
                    explicitDemoControls
                } else {
                    ContentUnavailableView(
                        "House detail is updating",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Reconnect once so HausKlar can load the server’s room and capability manifest.")
                    )
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await viewModel.refresh() }
    }

    private func houseGlanceSection(_ manifest: HomeManifestDTO) -> some View {
        let readings = roomTemperatureReadings(manifest)
        let boostActive = hotWaterBoostActive
        return VStack(alignment: .leading, spacing: 12) {
            Label("Room temperatures", systemImage: "thermometer.medium")
                .font(.headline)
                .foregroundStyle(.primary)

            if readings.isEmpty {
                Text("No room temperatures available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(readings) { reading in
                        Button {
                            selectedTemperatureRoom = reading
                            HapticManager.light()
                        } label: {
                            HStack(spacing: 10) {
                                Text(reading.name)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(reading.value.map { String(format: "%.1f°", $0) } ?? "—")
                                        .font(.body.weight(.semibold).monospacedDigit())
                                    if let dewPoint = reading.dewPoint {
                                        Text("Dew \(String(format: "%.1f°", dewPoint))")
                                            .font(.caption.weight(.semibold).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(reading.value == nil || reading.temperatureEntityId == nil)
                        .background(
                            reading.isHeating ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay {
                            if reading.isHeating {
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.orange.opacity(0.38))
                            }
                        }
                        .accessibilityLabel(temperatureAccessibilityLabel(reading))
                        .accessibilityHint("Opens the temperature graph and controls")
                    }
                }
            }

            Button {
                guard let heater = hotWaterHeater else { return }
                boostingHotWater = true
                HapticManager.light()
                Task {
                    await viewModel.setWaterHeaterMode(heater.entityId, mode: "on")
                    boostingHotWater = false
                }
            } label: {
                Label(
                    boostingHotWater
                        ? "Boosting…"
                        : boostActive
                            ? "Hot water boost active"
                            : hotWaterHeater == nil
                                ? "Hot water unavailable"
                                : "Boost hot water",
                    systemImage: "flame.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(boostActive ? .green : .orange)
            .disabled(hotWaterHeater == nil || !viewModel.canPerformActions || boostingHotWater || boostActive)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    private func fullControlsSection(_ manifest: HomeManifestDTO) -> some View {
        DisclosureGroup(isExpanded: $fullControlsExpanded) {
            LazyVStack(alignment: .leading, spacing: 20) {
                climateOverviewSection(manifest)
                favouritesSection(manifest)
                houseStateSection(manifest)
                roomsSection(manifest)
                advancedSection(manifest)
            }
            .padding(.top, 16)
        } label: {
            Label("Full controls", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func roomTemperatureReadings(_ manifest: HomeManifestDTO) -> [RoomTemperatureReading] {
        manifest.rooms.map { room in
            let roomEntities = room.entityIds.compactMap { viewModel.haClient.entities[$0] }
            let candidates: [(entityId: String, value: Double, priority: Int, name: String)] = roomEntities.compactMap { entity in
                guard let value = measuredTemperature(entity) else { return nil }
                let words = "\(entity.entityId) \(entity.friendlyName)".lowercased()
                let priority = entity.currentTemperature != nil ? 0 : words.contains("temperature") ? 1 : 2
                return (entity.entityId, value, priority, entity.friendlyName)
            }
            let best = candidates.sorted {
                $0.priority != $1.priority
                    ? $0.priority < $1.priority
                    : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }.first
            let roomWords = "\(room.id) \(room.name)".lowercased()
            let dewPoint = roomWords.contains("bathroom") || roomWords.contains("bath_room")
                ? roomEntities.compactMap(measuredDewPoint).first
                : nil
            let climateProfile = manifest.entities.first { profile in
                profile.roomId == room.id
                    && profile.controlKind == "climate"
                    && profile.capabilities.contains("set_temperature")
            }
            let climateEntity = climateProfile.flatMap { viewModel.haClient.entities[$0.entityId] }
            let thermostat = climateProfile.map { profile in
                HomeViewModel.HeatingRoom(
                    id: profile.entityId,
                    name: room.name,
                    currentTemp: climateEntity?.currentTemperature,
                    targetTemp: climateEntity?.targetTemperature,
                    isHeating: climateEntity?.hvacAction == "heating"
                )
            }
            return RoomTemperatureReading(
                id: room.id,
                name: room.name,
                value: best?.value,
                dewPoint: dewPoint,
                temperatureEntityId: best?.entityId,
                thermostat: thermostat,
                isHeating: roomEntities.contains { $0.hvacAction == "heating" }
            )
        }
    }

    private func temperatureAccessibilityLabel(_ reading: RoomTemperatureReading) -> String {
        var parts = [reading.name]
        if let value = reading.value {
            parts.append(String(format: "%.1f degrees", value))
        } else {
            parts.append("temperature unavailable")
        }
        if let dewPoint = reading.dewPoint {
            parts.append(String(format: "dew point %.1f degrees", dewPoint))
        }
        if reading.isHeating { parts.append("heating") }
        return parts.joined(separator: ", ")
    }

    private func measuredTemperature(_ entity: HAEntity) -> Double? {
        if let current = entity.currentTemperature { return current }
        let words = "\(entity.entityId) \(entity.friendlyName)".lowercased()
        if ["dew", "target", "setpoint", "apparent", "feels like"].contains(where: { words.contains($0) }) {
            return nil
        }
        let deviceClass = entity.attributes["device_class"]?.stringValue
        let unit = entity.attributes["unit_of_measurement"]?.stringValue?.lowercased()
        guard deviceClass == "temperature" || unit == "°c" || unit == "°f" else { return nil }
        return Double(entity.state)
    }

    private func measuredDewPoint(_ entity: HAEntity) -> Double? {
        let words = "\(entity.entityId) \(entity.friendlyName)".lowercased()
        guard ["dew point", "dew_point", "dewpoint"].contains(where: { words.contains($0) }) else {
            return nil
        }
        let deviceClass = entity.attributes["device_class"]?.stringValue
        let unit = entity.attributes["unit_of_measurement"]?.stringValue?.lowercased()
        guard deviceClass == "temperature" || unit == "°c" || unit == "°f" else { return nil }
        return Double(entity.state)
    }

    private var hotWaterHeater: HAEntity? {
        viewModel.haClient.entities.values
            .filter { $0.domain == "water_heater" }
            .sorted { $0.entityId < $1.entityId }
            .first
    }

    private var hotWaterBoostActive: Bool {
        viewModel.haClient.entities["binary_sensor.example_e5ed4cd5"]?.isOn == true
            || hotWaterHeater?.state == "on"
            || hotWaterHeater?.operationMode == "on"
    }

    private var demoModeBanner: some View {
        Label("Explicit demo mode · everything below is sample data", systemImage: "testtube.2")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Demo mode. Everything below is sample data.")
    }

    private var lastKnownBanner: some View {
        Label(
            "Showing the last confirmed house state. Controls are paused until the live connection returns.",
            systemImage: "wifi.slash"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func inlineError(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { viewModel.errorMessage = nil }
                .font(.subheadline.weight(.semibold))
        }
        .padding(12)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var sitrepSection: some View {
        if let sitrep = viewModel.sitrep {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: sitrep.tone == "calm" ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(sitrep.tone == "calm" ? Color.green : Color.orange)
                        .frame(width: 40, height: 40)
                        .background(.background, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("NOW")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(sitrep.headline)
                            .font(.title3.weight(.semibold))
                        Text(sitrep.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let date = ISODateParser.parse(sitrep.updatedAt) {
                        Text(date, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if sitrep.exceptions.isEmpty {
                    Label("No exceptions to deal with", systemImage: "checkmark.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    ForEach(sitrep.exceptions) { exception in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(exception.severity == "urgent" ? .red : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exception.title).font(.subheadline.weight(.semibold))
                                Text(exception.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                sitrep.tone == "calm" ? Color.green.opacity(0.09) : Color.orange.opacity(0.11),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
    }

    private func favouritesSection(_ manifest: HomeManifestDTO) -> some View {
        let favourites = manifest.entities.filter {
            $0.favourite && !$0.advanced && $0.controlKind != "mode"
        }
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(kicker: "ONE TAP", title: "Favourites") {
                Button {
                    showingFavourites = true
                } label: {
                    Label("Manage", systemImage: "star")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.presentationState != .live)
            }

            if favourites.isEmpty {
                ContentUnavailableView {
                    Label("No favourites yet", systemImage: "star")
                } description: {
                    Text("Choose the controls your family reaches for most.")
                } actions: {
                    Button("Choose favourites") { showingFavourites = true }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.presentationState != .live)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                    ForEach(favourites) { profile in
                        ManifestControlCard(
                            profile: profile,
                            entity: viewModel.haClient.entities[profile.entityId],
                            canPerformActions: viewModel.canPerformActions,
                            onActivate: { activate(profile) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func climateOverviewSection(_ manifest: HomeManifestDTO) -> some View {
        let profiles = manifest.entities
            .filter(isProminentClimateReading)
            .sorted {
                let left = $0.roomName ?? $0.name
                let right = $1.roomName ?? $1.name
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(kicker: "AT A GLANCE", title: "Temperatures & bathroom air") {
                    EmptyView()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 10)], spacing: 10) {
                    ForEach(profiles) { profile in
                        ManifestControlCard(
                            profile: profile,
                            entity: viewModel.haClient.entities[profile.entityId],
                            canPerformActions: viewModel.canPerformActions,
                            onActivate: { activate(profile) }
                        )
                    }
                }
            }
        }
    }

    private func isProminentClimateReading(_ profile: HomeManifestEntityDTO) -> Bool {
        guard !profile.advanced else { return false }
        if profile.controlKind == "climate" { return true }
        guard let entity = viewModel.haClient.entities[profile.entityId] else { return false }
        let words = [profile.entityId, profile.name, profile.roomId ?? "", profile.roomName ?? ""]
            .joined(separator: " ")
            .lowercased()
        let deviceClass = entity.attributes["device_class"]?.stringValue
        let unit = entity.attributes["unit_of_measurement"]?.stringValue?.lowercased()
        let temperature = deviceClass == "temperature"
            || unit == "°c"
            || unit == "°f"
            || words.contains("temperature")
        let bathroom = words.contains("bathroom") || words.contains("bath_room")
        let bathroomAir = bathroom && (
            deviceClass == "humidity"
                || words.contains("humidity")
                || words.contains("dew point")
                || words.contains("dew_point")
                || words.contains("dewpoint")
        )
        return temperature || bathroomAir
    }

    private func houseStateSection(_ manifest: HomeManifestDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(kicker: "DELIBERATE CONTROLS", title: "House state") { EmptyView() }

            if let selector = manifest.modeSelector {
                Button {
                    showingModePicker = true
                } label: {
                    intentionRow(
                        icon: "house.fill",
                        eyebrow: selector.name,
                        value: selector.current
                    )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canPerformActions)
                .accessibilityLabel("Change \(selector.name) from \(selector.current)")
            }

            Button {
                showingBroadAction = true
            } label: {
                intentionRow(
                    icon: "lightbulb.2.fill",
                    eyebrow: "Several lights",
                    value: "Choose scope and action"
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.presentationState != .live)
            .accessibilityLabel("Control several lights")
        }
    }

    private func roomsSection(_ manifest: HomeManifestDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(kicker: "BY PLACE", title: "Rooms") { EmptyView() }
            ForEach(manifest.rooms) { room in
                let profiles = room.entityIds.compactMap { entityId in
                    manifest.entities.first {
                        $0.entityId == entityId && !$0.advanced && $0.controlKind != "mode"
                    }
                }
                if !profiles.isEmpty {
                    ManifestRoomSection(
                        room: room,
                        profiles: profiles,
                        entities: viewModel.haClient.entities,
                        canPerformActions: viewModel.canPerformActions,
                        onActivate: activate
                    )
                }
            }
        }
    }

    private func advancedSection(_ manifest: HomeManifestDTO) -> some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    FloorPlanFullscreenView(viewModel: viewModel)
                } label: {
                    intentionRow(
                        icon: "map.fill",
                        eyebrow: "Private house map",
                        value: "2D, 3D, cameras and mesh"
                    )
                }
                .buttonStyle(.plain)

                let advancedProfiles = manifest.entities.filter(\.advanced)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diagnostics")
                        .font(.subheadline.weight(.semibold))
                    if advancedProfiles.isEmpty {
                        Text("No camera or mesh diagnostics are available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(advancedProfiles) { profile in
                            HStack {
                                Image(systemName: profile.controlKind == "camera" ? "camera.example_5f7f1d8c" : "wave.3.right")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name).font(.subheadline)
                                    Text(entitySummary(profile))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.top, 10)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced").font(.headline)
                    Text("Floor plan, cameras, mesh and diagnostics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "gearshape.2.fill")
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var explicitDemoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sample controls")
                .font(.headline)
            Text("The capability manifest is intentionally not invented in demo mode. These cards are clearly labelled local samples.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(viewModel.lightsOn) { light in
                HStack {
                    Label(light.name, systemImage: light.isOn ? "lightbulb.fill" : "lightbulb")
                    Spacer()
                    Text(light.isOn ? "On" : "Off").foregroundStyle(.secondary)
                }
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func sectionHeader<Accessory: View>(
        kicker: String,
        title: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(kicker)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(title).font(.title3.weight(.semibold))
            }
            Spacer()
            accessory()
        }
    }

    private func intentionRow(icon: String, eyebrow: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.semibold))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    private func activate(_ profile: HomeManifestEntityDTO) {
        let entity = viewModel.haClient.entities[profile.entityId]
        if profile.capabilities.contains("toggle") {
            Task {
                if profile.controlKind == "light" {
                    await viewModel.toggleLight(profile.entityId)
                } else {
                    await viewModel.toggleDevice(profile.entityId)
                }
                HapticManager.light()
            }
        } else if profile.capabilities.contains("set_temperature") {
            selectedTemperatureRoom = RoomTemperatureReading(
                id: profile.roomId ?? profile.entityId,
                name: profile.roomName ?? profile.name,
                value: entity?.currentTemperature,
                dewPoint: nil,
                temperatureEntityId: profile.entityId,
                thermostat: HomeViewModel.HeatingRoom(
                    id: profile.entityId,
                    name: profile.roomName ?? profile.name,
                    currentTemp: entity?.currentTemperature,
                    targetTemp: entity?.targetTemperature,
                    isHeating: entity?.hvacAction == "heating"
                ),
                isHeating: entity?.hvacAction == "heating"
            )
        } else if profile.capabilities.contains("play_pause") {
            Task {
                await viewModel.mediaPlayPause(profile.entityId)
                HapticManager.light()
            }
        } else if profile.capabilities.contains("activate") {
            pendingScene = profile
        }
    }

    private func entitySummary(_ profile: HomeManifestEntityDTO) -> String {
        guard let entity = viewModel.haClient.entities[profile.entityId] else {
            return "State unavailable"
        }
        if profile.controlKind == "climate", let temperature = entity.currentTemperature {
            return String(format: "%.1f° · %@", temperature, entity.hvacAction ?? entity.state)
        }
        if profile.controlKind == "media" {
            return entity.mediaTitle ?? entity.state.capitalized
        }
        if profile.controlKind == "sensor",
           let unit = entity.attributes["unit_of_measurement"]?.stringValue {
            return "\(entity.state) \(unit)"
        }
        return entity.state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var broadAlertTitle: String {
        pendingBroadAction?.action == "lights_on" ? "Turn these lights on?" : "Turn these lights off?"
    }

    private var broadConfirmLabel: String {
        pendingBroadAction?.action == "lights_on" ? "Turn lights on" : "Turn lights off"
    }

    private var broadAlertMessage: String {
        guard let choice = pendingBroadAction, let manifest = viewModel.manifest else { return "" }
        let profiles = manifest.entities.filter { profile in
            guard profile.isBroadControllableLight else { return false }
            switch choice.scope {
            case "favourites": return profile.favourite
            case "room": return profile.roomId == choice.roomId
            default: return true
            }
        }
        let scope: String
        switch choice.scope {
        case "favourites": scope = "favourite lights"
        case "room":
            scope = manifest.rooms.first(where: { $0.id == choice.roomId })?.name ?? "one room"
        default: scope = "every controllable light"
        }
        return "This will \(choice.action == "lights_on" ? "turn on" : "turn off") \(scope) (\(profiles.count) light\(profiles.count == 1 ? "" : "s")). No other devices will change."
    }
}

private struct ManifestControlCard: View {
    let profile: HomeManifestEntityDTO
    let entity: HAEntity?
    let canPerformActions: Bool
    let onActivate: () -> Void

    @ViewBuilder
    var body: some View {
        if isActionable {
            Button(action: onActivate) {
                cardContent
            }
            .buttonStyle(.plain)
            .disabled(!canPerformActions || entity == nil)
            .accessibilityHint(actionLabel)
        } else {
            cardContent
                .accessibilityElement(children: .combine)
                .accessibilityHint("Read only")
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(entity?.isOn == true ? Color.orange : Color.accentColor)
                Spacer()
                if isActionable {
                    Text(actionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(profile.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }

    private var isActionable: Bool {
        profile.capabilities.contains { $0 != "view" }
    }

    private var icon: String {
        switch profile.controlKind {
        case "light": return entity?.isOn == true ? "lightbulb.fill" : "lightbulb"
        case "climate": return "thermometer.medium"
        case "media": return "hifispeaker.fill"
        case "scene": return "play.circle.fill"
        case "switch": return "power"
        case "camera": return "camera.example_5f7f1d8c"
        default: return "gauge.with.dots.needle.50percent"
        }
    }

    private var actionLabel: String {
        if profile.capabilities.contains("toggle") { return entity?.isOn == true ? "Turn off" : "Turn on" }
        if profile.capabilities.contains("set_temperature") { return "Adjust" }
        if profile.capabilities.contains("play_pause") { return entity?.state == "playing" ? "Pause" : "Play" }
        if profile.capabilities.contains("activate") { return "Review" }
        return "Status"
    }

    private var summary: String {
        guard let entity else { return "State unavailable" }
        if profile.controlKind == "climate", let current = entity.currentTemperature {
            return String(format: "%.1f° now · %@", current, entity.hvacAction ?? entity.state)
        }
        if profile.controlKind == "media" {
            return entity.mediaTitle ?? entity.state.capitalized
        }
        if profile.controlKind == "sensor",
           let unit = entity.attributes["unit_of_measurement"]?.stringValue {
            return "\(entity.state) \(unit)"
        }
        return entity.state.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ManifestRoomSection: View {
    let room: HomeManifestRoomDTO
    let profiles: [HomeManifestEntityDTO]
    let entities: [String: HAEntity]
    let canPerformActions: Bool
    let onActivate: (HomeManifestEntityDTO) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                ForEach(profiles) { profile in
                    ManifestControlCard(
                        profile: profile,
                        entity: entities[profile.entityId],
                        canPerformActions: canPerformActions,
                        onActivate: { onActivate(profile) }
                    )
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name).font(.headline)
                    Text("\(profiles.count) signal\(profiles.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct HomeFavouritesSheet: View {
    let manifest: HomeManifestDTO
    let onSave: ([String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>
    @State private var saving = false

    init(manifest: HomeManifestDTO, onSave: @escaping ([String]) async -> Bool) {
        self.manifest = manifest
        self.onSave = onSave
        _selected = State(initialValue: Set(manifest.favouriteEntityIds))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(manifest.entities.filter { !$0.advanced && $0.controlKind != "mode" }) { profile in
                        Button {
                            if selected.contains(profile.entityId) {
                                selected.remove(profile.entityId)
                            } else if selected.count < 12 {
                                selected.insert(profile.entityId)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.roomName ?? profile.controlKind.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected.contains(profile.entityId) ? "star.fill" : "star")
                                    .foregroundStyle(selected.contains(profile.entityId) ? .yellow : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(!selected.contains(profile.entityId) && selected.count >= 12)
                    }
                } footer: {
                    Text("Choose up to 12. Favourites are shared for the family.")
                }
            }
            .navigationTitle("House favourites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            if await onSave(selected.sorted()) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }
}

private struct HomeModePicker: View {
    let selector: HomeModeSelectorDTO
    let onReview: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String

    init(selector: HomeModeSelectorDTO, onReview: @escaping (String) -> Void) {
        self.selector = selector
        self.onReview = onReview
        _selection = State(initialValue: selector.current)
    }

    var body: some View {
        NavigationStack {
            List(selector.options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(option).foregroundStyle(.primary)
                        Spacer()
                        if selection == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
            .navigationTitle("Choose house mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        dismiss()
                        onReview(selection)
                    }
                    .disabled(selection == selector.current)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct HomeBroadActionSheet: View {
    let manifest: HomeManifestDTO
    let onReview: (HomeBroadActionChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var action = "lights_off"
    @State private var scope: String
    @State private var roomId: String

    init(manifest: HomeManifestDTO, onReview: @escaping (HomeBroadActionChoice) -> Void) {
        self.manifest = manifest
        self.onReview = onReview
        let controllableLights = manifest.entities.filter { $0.isBroadControllableLight }
        let firstRoom = manifest.rooms.first(where: { room in
            controllableLights.contains { $0.roomId == room.id }
        })?.id ?? ""
        _roomId = State(initialValue: firstRoom)
        let initialScope = controllableLights.contains { $0.favourite }
            ? "favourites"
            : firstRoom.isEmpty ? "all" : "room"
        _scope = State(initialValue: initialScope)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Action") {
                    Picker("Action", selection: $action) {
                        Text("Turn lights off").tag("lights_off")
                        Text("Turn lights on").tag("lights_on")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Where") {
                    Picker("Scope", selection: $scope) {
                        ForEach(manifest.broadActionScopes, id: \.self) { value in
                            Text(scopeName(value)).tag(value)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if scope == "room" {
                        Picker("Room", selection: $roomId) {
                            ForEach(manifest.rooms.filter { room in
                                controllableLights.contains { $0.roomId == room.id }
                            }) { room in
                                Text(room.name).tag(room.id)
                            }
                        }
                    }
                }
                Section {
                    Text("\(targetCount) light\(targetCount == 1 ? "" : "s") match this scope. Nothing runs until you review and confirm.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Control several lights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        let choice = HomeBroadActionChoice(
                            action: action,
                            scope: scope,
                            roomId: scope == "room" ? roomId : nil
                        )
                        dismiss()
                        onReview(choice)
                    }
                    .disabled(targetCount == 0)
                }
            }
        }
    }

    private var targetCount: Int {
        controllableLights.filter { profile in
            switch scope {
            case "favourites": return profile.favourite
            case "room": return profile.roomId == roomId
            default: return true
            }
        }.count
    }

    private var controllableLights: [HomeManifestEntityDTO] {
        manifest.entities.filter { $0.isBroadControllableLight }
    }

    private func scopeName(_ value: String) -> String {
        switch value {
        case "favourites": return "Favourite lights"
        case "room": return "One room"
        default: return "All controllable lights"
        }
    }
}

private extension HomeManifestEntityDTO {
    var isBroadControllableLight: Bool {
        controlKind == "light"
            && (capabilities.contains("turn_on") || capabilities.contains("turn_off"))
    }
}

/// One calm room surface: current temperature, real history, then the likely next control.
private struct RoomTemperatureControlSheet: View {
    let room: RoomTemperatureReading
    @ObservedObject var viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var targetTemp: Double
    @State private var debounceTask: Task<Void, Never>?
    @State private var isSettingTemperature = false
    @State private var moreControlsExpanded = false

    init(room: RoomTemperatureReading, viewModel: HomeViewModel) {
        self.room = room
        self.viewModel = viewModel
        let fallback = ((room.value ?? 20) * 2).rounded() / 2
        _targetTemp = State(initialValue: room.thermostat?.targetTemp ?? fallback)
    }

    private var entity: HAEntity? {
        guard let thermostat = room.thermostat else { return nil }
        return viewModel.haClient.entities[thermostat.id]
    }

    private var currentTemperature: Double? {
        entity?.currentTemperature ?? room.value
    }

    private var isHeating: Bool {
        entity?.hvacAction == "heating" || room.isHeating
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: isHeating ? "flame.fill" : "thermometer.medium")
                            .font(.title2)
                            .foregroundStyle(isHeating ? Color.orange : Color.accentColor)
                            .frame(width: 40, height: 40)
                            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))

                        temperatureValue("Now", value: currentTemperature)
                        if let dewPoint = room.dewPoint {
                            Divider().frame(height: 34)
                            temperatureValue("Dew point", value: dewPoint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background(
                        isHeating ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .overlay {
                        if isHeating {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.orange.opacity(0.38))
                        }
                    }

                    if let temperatureEntityId = room.temperatureEntityId {
                        TemperatureHistoryPanel(
                            entityId: temperatureEntityId,
                            isHeating: isHeating
                        )
                    }

                    if room.thermostat != nil {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Target")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f°", targetTemp))
                                    .font(.title2.weight(.semibold).monospacedDigit())
                            }
                            Spacer()
                            HStack(spacing: 10) {
                                targetButton(
                                    systemImage: "minus",
                                    label: "Lower \(room.name) target temperature",
                                    disabled: isSettingTemperature || targetTemp <= (entity?.minTemp ?? 5),
                                    delta: -0.5
                                )
                                targetButton(
                                    systemImage: "plus",
                                    label: "Raise \(room.name) target temperature",
                                    disabled: isSettingTemperature || targetTemp >= (entity?.maxTemp ?? 30),
                                    delta: 0.5
                                )
                            }
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .bottomLeading) {
                            if isSettingTemperature {
                                Text("Setting…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 4)
                            }
                        }
                    }

                    if let thermostat = room.thermostat,
                       let entity,
                       !entity.hvacModes.isEmpty || entity.presetModes.contains("boost") {
                        DisclosureGroup(isExpanded: $moreControlsExpanded) {
                            VStack(spacing: 16) {
                                if !entity.hvacModes.isEmpty {
                                    Picker("Mode", selection: Binding(
                                        get: { entity.state },
                                        set: { newMode in
                                            Task { await viewModel.setHVACMode(thermostat.id, mode: newMode) }
                                        }
                                    )) {
                                        ForEach(entity.hvacModes, id: \.self) { mode in
                                            Text(mode.capitalized).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                }

                                if entity.presetModes.contains("boost") {
                                    Button {
                                        Task { await viewModel.setPresetMode(thermostat.id, preset: "boost") }
                                    } label: {
                                        Label(
                                            entity.presetMode == "boost" ? "Boosting" : "Boost heating",
                                            systemImage: "flame.fill"
                                        )
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.orange)
                                }
                            }
                            .padding(.top, 14)
                        } label: {
                            Label("More heating controls", systemImage: "slider.horizontal.3")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding()
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(room.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear { debounceTask?.cancel() }
    }

    private func temperatureValue(_ label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%.1f°", $0) } ?? "—")
                .font(.title2.weight(.semibold).monospacedDigit())
        }
    }

    private func targetButton(
        systemImage: String,
        label: String,
        disabled: Bool,
        delta: Double
    ) -> some View {
        Button { adjustTarget(by: delta) } label: {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func adjustTarget(by delta: Double) {
        let minTemp = entity?.minTemp ?? 5.0
        let maxTemp = entity?.maxTemp ?? 30.0
        targetTemp = max(minTemp, min(maxTemp, targetTemp + delta))
        HapticManager.selection()
        debounceTask?.cancel()
        let requestedTemperature = targetTemp
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let thermostat = room.thermostat else { return }
            isSettingTemperature = true
            await viewModel.setTemperature(thermostat.id, temperature: requestedTemperature)
            isSettingTemperature = false
        }
    }
}

private struct TemperatureHistoryPanel: View {
    let entityId: String
    let isHeating: Bool

    @State private var points: [HAClient.TemperatureHistoryPoint] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var tint: Color { isHeating ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLoading {
                historySkeleton
            } else if errorMessage != nil {
                VStack(spacing: 10) {
                    Text("Couldn’t load the graph.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 210)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            } else if points.isEmpty {
                Text("No recent readings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 210)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            } else {
                historyChart
            }
        }
        .task(id: entityId) { await load() }
    }

    private var historySkeleton: some View {
        VStack(spacing: 36) {
            ForEach(0..<4, id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.14))
                    .frame(height: 1)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 210)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading temperature graph")
    }

    private var historyChart: some View {
        let temperatures = points.map(\.temperature)
        let rawMinimum = temperatures.min() ?? 0
        let rawMaximum = temperatures.max() ?? 1
        let padding = max(0.5, (rawMaximum - rawMinimum) * 0.15)
        let domain = (rawMinimum - padding)...(rawMaximum + padding)
        let lastPoint = points.last

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last 24 hours")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f–%.1f°", rawMinimum, rawMaximum))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.recordedAt),
                    yStart: .value("Minimum", domain.lowerBound),
                    yEnd: .value("Temperature", point.temperature)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.24), tint.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.recordedAt),
                    y: .value("Temperature", point.temperature)
                )
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                if point.id == lastPoint?.id {
                    PointMark(
                        x: .value("Time", point.recordedAt),
                        y: .value("Temperature", point.temperature)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(42)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                String(
                    format: "Temperature ranged from %.1f to %.1f degrees over the last 24 hours",
                    rawMinimum,
                    rawMaximum
                )
            )
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            points = try await HAClient.shared.fetchTemperatureHistory(entityId: entityId)
        } catch is CancellationError {
            return
        } catch {
            points = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
