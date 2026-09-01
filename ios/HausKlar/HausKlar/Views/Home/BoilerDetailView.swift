import SwiftUI

/// Detailed boiler panel showing water heater state, central heating status,
/// actively-calling TRVs, and overall system status badge.
struct BoilerDetailView: View {
    let viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss

    private static let green = Color.hackerGreen
    private static let red = Color.hackerRed
    private static let orange = Color.hackerOrange
    private static let cyan = Color.hackerCyan
    private static let grey = Color.hackerGrey

    private var waterHeater: HAEntity? {
        viewModel.haClient.entities["water_heater.thermostat_3"]
    }

    private var hwStateEntity: HAEntity? {
        viewModel.haClient.entities["binary_sensor.example_41b7d1dd"]
    }

    private var hwBoostEntity: HAEntity? {
        viewModel.haClient.entities["binary_sensor.example_e5ed4cd5"]
    }

    private var hwModeEntity: HAEntity? {
        viewModel.haClient.entities["sensor.example_7d804507"]
    }

    /// All climate entities with hvac_action == "heating"
    private var activelyHeatingTRVs: [HAEntity] {
        viewModel.haClient.entities(inDomain: "climate").filter { $0.hvacAction == "heating" }
    }

    /// Overall status: BOTH ON / HW ONLY / CH ONLY / IDLE
    private var systemStatus: (label: String, color: Color) {
        let hwOn = hwStateEntity?.isOn == true
        let chOn = !activelyHeatingTRVs.isEmpty
        switch (hwOn, chOn) {
        case (true, true): return ("BOTH ON", Self.orange)
        case (true, false): return ("HW ONLY", Self.cyan)
        case (false, true): return ("CH ONLY", Self.orange)
        case (false, false): return ("IDLE", Self.grey)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BOILER SYSTEM")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.green)
                    Text("DETAILED STATUS")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Self.grey)
                        .tracking(1)
                }

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.gray)
                }
            }
            .padding()

            Divider().background(Self.green.opacity(0.2))

            ScrollView {
                VStack(spacing: 20) {
                    // System status badge
                    systemStatusBadge

                    // Hot water section
                    hotWaterSection

                    Divider().background(Self.green.opacity(0.2))

                    // Water heating mode controls
                    waterHeatingModeSection

                    Divider().background(Self.green.opacity(0.2))

                    // Central heating section
                    centralHeatingSection

                    // Actively calling TRVs
                    if !activelyHeatingTRVs.isEmpty {
                        Divider().background(Self.green.opacity(0.2))
                        activeTRVsSection
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    // MARK: - System Status Badge

    private var systemStatusBadge: some View {
        let status = systemStatus
        return HStack(spacing: 8) {
            Circle()
                .fill(status.color)
                .frame(width: 12, height: 12)
            Text(status.label)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(status.color)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(status.color.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(status.color.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Hot Water Section

    private var hotWaterSection: some View {
        VStack(spacing: 12) {
            sectionHeader("HOT WATER")

            let hwOn = hwStateEntity?.isOn == true
            statusRow("Status", value: hwOn ? "ON" : "OFF",
                      color: hwOn ? Self.orange : Self.grey)

            // Boost
            if hwBoostEntity?.isOn == true {
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

            // Mode
            if let modeValue = hwModeEntity?.state,
               modeValue != "unknown" && modeValue != "unavailable" {
                statusRow("Mode", value: modeValue.uppercased(), color: Self.cyan)
            }

            // Water heater entity state
            if let wh = waterHeater {
                statusRow("Water Heater", value: wh.state.uppercased(), color: Self.green)
            }
        }
    }

    // MARK: - Water Heating Mode

    private var waterHeatingModeSection: some View {
        VStack(spacing: 12) {
            sectionHeader("WATER HEATING MODE")

            let currentMode = waterHeater?.state ?? "unknown"

            HStack(spacing: 8) {
                ForEach([("eco", "SCHEDULE", Self.green),
                         ("on", "ON", Self.orange),
                         ("off", "OFF", Self.red)], id: \.0) { mode, label, color in
                    let isActive = currentMode == mode
                    Button {
                        HapticManager.light()
                        Task { await viewModel.setWaterHeaterMode("water_heater.thermostat_3", mode: mode) }
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isActive ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
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
    }

    // MARK: - Central Heating Section

    private var centralHeatingSection: some View {
        VStack(spacing: 12) {
            sectionHeader("CENTRAL HEATING")

            let trvs = viewModel.heatingRooms
            let heatingCount = trvs.filter(\.isHeating).count

            statusRow("TRVs Calling",
                      value: "\(heatingCount)/\(trvs.count)",
                      color: heatingCount > 0 ? Self.orange : Self.grey)

            statusRow("Status",
                      value: heatingCount > 0 ? "ACTIVE" : "IDLE",
                      color: heatingCount > 0 ? Self.orange : Self.grey)
        }
    }

    // MARK: - Active TRVs

    private var activeTRVsSection: some View {
        VStack(spacing: 12) {
            sectionHeader("ACTIVELY HEATING")

            ForEach(activelyHeatingTRVs) { trv in
                HStack {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Self.orange)

                    Text(trv.friendlyName)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white)

                    Spacer()

                    if let current = trv.currentTemperature {
                        Text(String(format: "%.1f\u{00B0}", current))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Self.green)
                    }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Self.grey)

                    if let target = trv.targetTemperature {
                        Text(String(format: "%.1f\u{00B0}", target))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Self.orange)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Self.grey)
            .tracking(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(_ label: String, value: String, color: Color) -> some View {
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
}
