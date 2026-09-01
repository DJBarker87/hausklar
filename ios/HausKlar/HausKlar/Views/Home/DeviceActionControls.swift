import Foundation
import SwiftUI

extension DeviceActionSheet {
    var lightPlugContent: some View {
        VStack(spacing: 16) {
            statusRow(
                "Status", value: entity?.isOn == true ? "ON" : "OFF",
                color: entity?.isOn == true ? Self.green : Self.grey)

            if device.type == "light", entity?.brightness != nil {
                VStack(spacing: 4) {
                    HStack {
                        Text("Brightness")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Self.grey)
                        Spacer()
                        Text("\(Int(brightnessSlider))%")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Self.green)
                    }
                    Slider(value: $brightnessSlider, in: 1...100, step: 1) { editing in
                        if !editing {
                            let haValue = Int(brightnessSlider * 2.55)
                            Task {
                                await viewModel.performAction(
                                    domain: "light", service: "turn_on",
                                    data: ["entity_id": device.entityId, "brightness": haValue]
                                )
                            }
                        }
                    }
                    .tint(Self.green)
                }
                .onAppear {
                    if let b = entity?.brightness {
                        brightnessSlider = Double(b) / 255.0 * 100.0
                    }
                }
                .onChange(of: entity?.brightness) { _, newVal in
                    if let b = newVal {
                        brightnessSlider = Double(b) / 255.0 * 100.0
                    }
                }
            }

            Button {
                HapticManager.medium()
                Task { await viewModel.toggleDevice(device.entityId) }
            } label: {
                Text(entity?.isOn == true ? "TURN OFF" : "TURN ON")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(entity?.isOn == true ? .black : .white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(entity?.isOn == true ? Self.green : Self.grey.opacity(0.3))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(entity?.isOn == true ? Self.green : Self.grey, lineWidth: 1)
                    )
            }

            // History chart
            Divider().background(Self.green.opacity(0.2))
            VStack(spacing: 4) {
                Text("HISTORY")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .tracking(1)
                HistoryChartView(entityId: device.entityId)
            }
        }
    }

    var trvContent: some View {
        VStack(spacing: 16) {
            if let current = entity?.currentTemperature {
                statusRow(
                    "Current", value: String(format: "%.1f\u{00B0}C", current),
                    color: Self.green)
            }
            if let target = entity?.targetTemperature {
                statusRow(
                    "Target", value: String(format: "%.1f\u{00B0}C", target),
                    color: Self.green)
            }
            let hvac = entity?.hvacAction ?? "off"
            statusRow(
                "Status", value: hvac.uppercased() + (hvac == "heating" ? " \u{1F525}" : ""),
                color: hvac == "heating" ? Self.orange : hvac == "idle" ? Self.green : Self.grey)

            VStack(spacing: 8) {
                Text("TEMPERATURE")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .tracking(1)

                Text(String(format: "%.1f\u{00B0}C", trvSliderEditing ? trvSliderValue : (entity?.targetTemperature ?? 20.0)))
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .accessibilityLabel(
                        "Target temperature \(String(format: "%.1f", trvSliderEditing ? trvSliderValue : (entity?.targetTemperature ?? 20.0))) degrees"
                    )

                HStack(spacing: 8) {
                    Text("5\u{00B0}")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)

                    Slider(value: $trvSliderValue, in: 5...30, step: 0.5) { editing in
                        trvSliderEditing = editing
                        if !editing {
                            HapticManager.selection()
                            Task { await viewModel.setTemperature(device.entityId, temperature: trvSliderValue) }
                        }
                    }
                    .tint(Self.green)

                    Text("30\u{00B0}")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)
                }
            }
            .onAppear {
                trvSliderValue = entity?.targetTemperature ?? 20.0
            }
            .onChange(of: entity?.targetTemperature) { _, newValue in
                if !trvSliderEditing, let v = newValue {
                    trvSliderValue = v
                }
            }

            let modes = entity?.hvacModes ?? []
            if !modes.isEmpty {
                VStack(spacing: 8) {
                    Text("MODE")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)
                        .tracking(1)

                    HStack(spacing: 8) {
                        ForEach(modes, id: \.self) { mode in
                            let isActive = entity?.state == mode
                            Button {
                                Task { await viewModel.setHVACMode(device.entityId, mode: mode) }
                            } label: {
                                Text(mode.uppercased())
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(isActive ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isActive ? Self.green : Self.grey.opacity(0.3))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(isActive ? Self.green : Self.grey.opacity(0.5), lineWidth: 1)
                                    )
                            }
                        }
                    }
                }
            }

            let presets = entity?.presetModes ?? []
            if !presets.isEmpty {
                VStack(spacing: 8) {
                    Text("PRESET")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)
                        .tracking(1)

                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { preset in
                            let isActive = entity?.presetMode == preset
                            let presetColor = presetButtonColor(preset)
                            Button {
                                Task { await viewModel.setPresetMode(device.entityId, preset: preset) }
                            } label: {
                                Text(preset.uppercased())
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(isActive ? .black : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isActive ? presetColor : Self.grey.opacity(0.3))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(isActive ? presetColor : Self.grey.opacity(0.5), lineWidth: 1)
                                    )
                            }
                        }
                    }
                }
            }

            // History chart
            Divider().background(Self.green.opacity(0.2))
            VStack(spacing: 4) {
                Text("HISTORY")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .tracking(1)
                HistoryChartView(entityId: device.entityId, isClimate: true)
            }
        }
    }

    var contactContent: some View {
        VStack(spacing: 12) {
            let isOpen = entity?.isOn == true
            statusRow(
                "Status", value: isOpen ? "OPEN" : "CLOSED",
                color: isOpen ? Self.red : Self.green)

            if let event = doorEvent {
                let timeStr = ISODateParser.timeOnly(from: event.openedAt)
                if event.isStillOpen {
                    statusRow(
                        "Last opened", value: "\(timeStr) (still open)",
                        color: Self.orange)
                } else if let dur = event.duration {
                    statusRow(
                        "Last opened", value: "\(timeStr) for \(Self.formatContactDuration(dur))",
                        color: Self.grey)
                } else {
                    statusRow("Last opened", value: timeStr, color: Self.grey)
                }
            }

            Button {
                HapticManager.light()
                showDoorHistory = true
            } label: {
                Text("VIEW HISTORY")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Self.green.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Self.green.opacity(0.3), lineWidth: 1)
                    )
            }
            .sheet(isPresented: $showDoorHistory) {
                DoorHistoryView(entityId: device.entityId, deviceLabel: device.label)
            }
        }
        .task {
            doorEvent = await viewModel.haClient.fetchDoorHistory(entityId: device.entityId)
        }
    }

    private static func formatContactDuration(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        let remainder = secs % 60
        if remainder == 0 { return "\(mins)m" }
        return "\(mins)m \(remainder)s"
    }

    // MARK: - Other Content Views

    var applianceContent: some View {
        VStack(spacing: 12) {
            let state = entity?.state ?? "unknown"
            let isRunning = state != "off" && state != "unavailable" && state != "unknown"
            statusRow(
                "Status", value: state.uppercased(),
                color: isRunning ? Self.cyan : Self.grey)

            // Derive prefix from entity ID (e.g. "sensor.example_5e6551b9" → "dishwasher")
            let prefix = appliancePrefix(from: device.entityId)

            // Program
            if let prog = lookupApplianceEntity(prefix: prefix, suffixes: ["_program", "_programme"]) {
                statusRow("Program", value: prog.capitalized, color: Self.cyan)
            }

            // Phase
            if let phase = lookupApplianceEntity(prefix: prefix, suffixes: ["_programme_phase", "_phase"]) {
                statusRow("Phase", value: phase.capitalized, color: .white)
            }

            // Time remaining
            if let remaining = lookupApplianceEntity(prefix: prefix, suffixes: ["_time_remaining", "_remaining_time"]) {
                statusRow("Remaining", value: remaining, color: Self.green)
            }

            // Time elapsed
            if let elapsed = lookupApplianceEntity(prefix: prefix, suffixes: ["_time_elapsed", "_elapsed_time"]) {
                statusRow("Elapsed", value: elapsed, color: Self.grey)
            }

            // Door status
            if let doorEntity = viewModel.haClient.entities["binary_sensor.\(prefix)_door"] {
                let doorOpen = doorEntity.isOn
                statusRow(
                    "Door", value: doorOpen ? "OPEN" : "CLOSED",
                    color: doorOpen ? Self.red : Self.green)
            }

            // Energy consumption
            if let energy = lookupApplianceEntity(prefix: prefix, suffixes: ["_energy_consumption"]) {
                statusRow("Energy", value: "\(energy) kWh", color: Self.orange)
            }

            // Water consumption
            if let water = lookupApplianceEntity(prefix: prefix, suffixes: ["_water_consumption"]) {
                statusRow("Water", value: "\(water) L", color: Self.cyan)
            }

            // History chart
            Divider().background(Self.green.opacity(0.2))
            VStack(spacing: 4) {
                Text("HISTORY")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .tracking(1)
                HistoryChartView(entityId: device.entityId)
            }
        }
    }

    private func appliancePrefix(from entityId: String) -> String {
        // "sensor.example_5e6551b9" → "dishwasher"
        let withoutDomain = entityId.components(separatedBy: ".").last ?? entityId
        // Remove common suffixes like _status
        return
            withoutDomain
            .replacingOccurrences(of: "_status", with: "")
    }

    private func lookupApplianceEntity(prefix: String, suffixes: [String]) -> String? {
        for suffix in suffixes {
            if let entity = viewModel.haClient.entities["sensor.\(prefix)\(suffix)"],
                entity.state != "unavailable" && entity.state != "unknown"
            {
                return entity.state
            }
        }
        return nil
    }

    var boilerContent: some View {
        VStack(spacing: 16) {
            // Hot water status
            let hwEntity = viewModel.haClient.entities["binary_sensor.example_41b7d1dd"]
            let hwOn = hwEntity?.isOn == true
            statusRow(
                "Hot Water", value: hwOn ? "ON" : "OFF",
                color: hwOn ? Self.orange : Self.grey)

            // Boost indicator
            let boostEntity = viewModel.haClient.entities["binary_sensor.example_e5ed4cd5"]
            if boostEntity?.isOn == true {
                Text("BOOST ACTIVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .tracking(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Self.orange)
                    )
            }

            // Current mode display
            let modeEntity = viewModel.haClient.entities["sensor.example_7d804507"]
            if let modeValue = modeEntity?.state, modeValue != "unknown" && modeValue != "unavailable" {
                statusRow("Mode", value: modeValue.uppercased(), color: Self.cyan)
            }

            // Central Heating status (TRVs calling)
            let trvs = viewModel.heatingRooms
            let heatingCount = trvs.filter(\.isHeating).count
            statusRow(
                "Central Heating",
                value: heatingCount > 0 ? "\(heatingCount)/\(trvs.count) TRVs CALLING" : "IDLE",
                color: heatingCount > 0 ? Self.orange : Self.grey)

            Divider().background(Self.green.opacity(0.2))

            // Water heating mode buttons
            let waterHeater = viewModel.haClient.entities["water_heater.thermostat_3"]
            let currentMode = waterHeater?.state ?? "unknown"

            VStack(spacing: 8) {
                Text("WATER HEATING MODE")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .tracking(1)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    ForEach(
                        [
                            ("eco", "SCHEDULE", Self.green),
                            ("on", "ON", Self.orange),
                            ("off", "OFF", Self.red),
                        ], id: \.0
                    ) { mode, label, color in
                        let isActive = currentMode == mode
                        Button {
                            HapticManager.light()
                            viewModel.errorMessage = nil
                            Task { await viewModel.setWaterHeaterMode("water_heater.thermostat_3", mode: mode) }
                        } label: {
                            Text(label)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(isActive ? .black : .white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isActive ? color : Self.grey.opacity(0.3))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isActive ? color : Self.grey.opacity(0.5), lineWidth: 1)
                                )
                        }
                    }
                }
            }

            Button {
                HapticManager.light()
                showBoilerDetail = true
            } label: {
                Text("DETAILS")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Self.green.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Self.green.opacity(0.3), lineWidth: 1)
                    )
            }
            .sheet(isPresented: $showBoilerDetail) {
                BoilerDetailView(viewModel: viewModel)
            }
        }
    }

    var motionContent: some View {
        VStack(spacing: 12) {
            let detected = entity?.isOn == true
            statusRow(
                "Status", value: detected ? "DETECTED" : "CLEAR",
                color: detected ? Self.orange : Self.grey)

            // History chart
            Divider().background(Self.green.opacity(0.2))
            VStack(spacing: 4) {
                Text("HISTORY")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .tracking(1)
                HistoryChartView(entityId: device.entityId)
            }
        }
    }

    var temperatureContent: some View {
        VStack(spacing: 12) {
            if let state = entity?.state, let temp = Double(state) {
                // Derive humidity entity by replacing _temperature with _humidity
                let humidityId = device.entityId.replacingOccurrences(of: "_temperature", with: "_humidity")
                let humidityEntity = viewModel.haClient.entities[humidityId]

                if let humState = humidityEntity?.state, let humidity = Double(humState) {
                    // Show combined: "21.5°C | 65%"
                    HStack {
                        Text("Reading")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Self.grey)
                        Spacer()
                        Text(String(format: "%.1f\u{00B0}C", temp))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Self.green)
                        Text("|")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Self.grey)
                        Text(String(format: "%.0f%%", humidity))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Self.cyan)
                    }

                    // Dew point + mould risk for bathroom sensor
                    if device.entityId == "sensor.example_4b73e4e4" {
                        let dewPointEntity = viewModel.haClient.entities["sensor.example_71c4f84f"]
                        let mouldRiskEntity = viewModel.haClient.entities["sensor.example_4640c816"]

                        if let dpState = dewPointEntity?.state, let dp = Double(dpState) {
                            HStack {
                                Text("Dew Point")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Self.grey)
                                Spacer()
                                Text(String(format: "%.1f\u{00B0}C", dp))
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Self.orange)
                            }
                        }

                        if let risk = mouldRiskEntity?.state {
                            let riskColor: Color =
                                switch risk {
                                case "Critical": Self.red
                                case "High": Self.orange
                                case "Moderate": Self.cyan
                                default: Self.green
                                }
                            HStack {
                                Text("Mould Risk")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Self.grey)
                                Spacer()
                                Text(risk.uppercased())
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(riskColor)
                            }
                        }
                    }
                } else {
                    statusRow(
                        "Reading", value: String(format: "%.1f\u{00B0}C", temp),
                        color: Self.green)
                }
            } else {
                statusRow(
                    "Reading", value: entity?.state ?? "unknown",
                    color: Self.grey)
            }

            // History chart
            Divider().background(Self.green.opacity(0.2))
            VStack(spacing: 4) {
                Text("HISTORY")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .tracking(1)
                HistoryChartView(entityId: device.entityId, isClimate: false)
            }
        }
    }

    var genericContent: some View {
        VStack(spacing: 12) {
            statusRow(
                "State", value: (entity?.state ?? "unknown").uppercased(),
                color: Self.grey)
        }
    }

    // MARK: - TRV Helpers

    private func presetButtonColor(_ preset: String) -> Color {
        switch preset.lowercased() {
        case "boost": return Self.orange
        case "schedule": return Self.green
        default: return Self.green
        }
    }

    // MARK: - Helpers

    func statusRow(_ label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Self.grey)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    var deviceIcon: some View {
        Group {
            switch device.type {
            case "light":
                Image(systemName: "lightbulb.fill")
            case "plug":
                Image(systemName: "powerplug.fill")
            case "trv":
                Image(systemName: "thermometer.medium")
            case "contact":
                Image(systemName: entity?.isOn == true ? "door.left.hand.open" : "door.left.hand.closed")
            case "speaker":
                Image(systemName: "hifispeaker.fill")
            case "appliance":
                Image(systemName: "washer.fill")
            case "boiler":
                Image(systemName: "flame.fill")
            case "motion":
                Image(systemName: "figure.walk")
            case "temperature":
                Image(systemName: "thermometer")
            case "camera":
                Image(systemName: "video.fill")
            default:
                Image(systemName: "sensor.example_a366a185")
            }
        }
    }

    var accentColor: Color {
        DeviceColors.accentColor(for: device.type, entity: entity)
    }
}
