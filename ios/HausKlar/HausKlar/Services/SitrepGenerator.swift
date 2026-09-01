import Foundation

/// Client-side SITREP generator — ports generateSitrep.ts logic to Swift.
/// Generates a tactical situation report from HA entity data. No Ollama needed.
struct SitrepGenerator {

    static func generate(entities: [String: HAEntity]) -> String {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        var lines: [String] = []

        lines.append("SITREP \(time)")
        lines.append("━━━━━━━━━━━━━━━━━━━━")
        lines.append("SECURITY: \(security(entities).joined(separator: " "))")
        lines.append("CLIMATE: \(climate(entities).joined(separator: " "))")
        lines.append("OCCUPANCY: \(occupancy(entities).joined(separator: " "))")

        if let p = presence(entities) {
            lines.append("PRESENCE: \(p.joined(separator: " "))")
        }
        if let m = media(entities) {
            lines.append("MEDIA: \(m.joined(separator: " | "))")
        }

        lines.append("LIGHTS: \(lights(entities).joined(separator: " "))")
        lines.append("APPLIANCES: \(appliances(entities).joined(separator: " "))")
        lines.append("ANOMALY: \(anomalies(entities).joined(separator: " "))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func name(_ e: HAEntity) -> String {
        e.friendlyName
    }

    private static func byDomain(_ entities: [String: HAEntity], _ domain: String) -> [HAEntity] {
        entities.values
            .filter { $0.entityId.hasPrefix("\(domain).") && $0.state != "unavailable" && $0.state != "unknown" }
            .sorted { $0.entityId < $1.entityId }
    }

    private static func minutesAgo(_ iso: String) -> Int {
        guard let date = ISODateParser.parse(iso) else { return 0 }
        return Int(Date().timeIntervalSince(date) / 60)
    }

    private static let applianceDoorIds = Set(["binary_sensor.example_92877e76", "binary_sensor.example_a401a1ce"])

    // MARK: - Sections

    private static func security(_ entities: [String: HAEntity]) -> [String] {
        let doors = byDomain(entities, "binary_sensor").filter {
            let dc = $0.attributes["device_class"]?.stringValue
            return (dc == "door" || dc == "opening") && !applianceDoorIds.contains($0.entityId)
        }
        if doors.isEmpty { return ["No door sensors found."] }
        let open = doors.filter { $0.state == "on" }
        if open.isEmpty { return ["All doors secure."] }
        return open.map { "ALERT: \(name($0)) OPEN." }
    }

    private static func climate(_ entities: [String: HAEntity]) -> [String] {
        let all = entities.values.filter { $0.entityId.hasPrefix("climate.") }
        let unavailable = all.filter { $0.state == "unavailable" }
        let climates = all.filter { $0.state != "unavailable" && $0.state != "unknown" }
        if climates.isEmpty && unavailable.isEmpty { return ["No climate data."] }

        var warmest: HAEntity?
        var coldest: HAEntity?
        var heatingCount = 0

        for e in climates {
            guard let temp = e.currentTemperature else { continue }
            if let currentWarmest = warmest?.currentTemperature {
                if temp > currentWarmest { warmest = e }
            } else {
                warmest = e
            }
            if let currentColdest = coldest?.currentTemperature {
                if temp < currentColdest { coldest = e }
            } else {
                coldest = e
            }
            if e.hvacAction == "heating" { heatingCount += 1 }
        }

        var lines: [String] = []
        if let w = warmest, let c = coldest,
           let wt = w.currentTemperature, let ct = c.currentTemperature {
            lines.append("Warmest: \(name(w)) at \(String(format: "%.1f", wt))°C. Coldest: \(name(c)) at \(String(format: "%.1f", ct))°C.")
        }
        lines.append("\(heatingCount) TRV\(heatingCount == 1 ? "" : "s") heating.")
        if !unavailable.isEmpty {
            lines.append("WARNING: \(unavailable.count) TRV\(unavailable.count == 1 ? "" : "s") unavailable.")
        }
        return lines
    }

    private static func occupancy(_ entities: [String: HAEntity]) -> [String] {
        let motion = byDomain(entities, "binary_sensor").filter {
            $0.attributes["device_class"]?.stringValue == "motion"
        }
        if motion.isEmpty { return ["No motion sensors found."] }

        let active = motion.filter { $0.state == "on" }
        if !active.isEmpty {
            return ["Motion detected: \(active.map { name($0) }.joined(separator: ", "))."]
        }

        let sorted = motion.sorted { $0.lastChanged > $1.lastChanged }
        if let last = sorted.first {
            let mins = minutesAgo(last.lastChanged)
            return ["All clear. Last motion: \(name(last)) \(mins) min ago."]
        }
        return ["All clear."]
    }

    private static func presence(_ entities: [String: HAEntity]) -> [String]? {
        let trackers = byDomain(entities, "device_tracker")
        let presenceSensors = byDomain(entities, "binary_sensor").filter {
            $0.attributes["device_class"]?.stringValue == "presence"
        }
        let all = trackers + presenceSensors
        if all.isEmpty { return nil }

        var home: [String] = []
        var away: [String] = []

        for e in all {
            let isHome = e.state == "home" || e.state == "on"
            let personName = name(e).replacingOccurrences(of: " Home", with: "", options: .caseInsensitive)
            if isHome { home.append(personName) } else { away.append(personName) }
        }

        if home.isEmpty && away.isEmpty { return nil }
        if away.isEmpty { return ["All home."] }
        if home.isEmpty { return ["House empty."] }
        return ["Home: \(home.joined(separator: ", ")). Away: \(away.joined(separator: ", "))."]
    }

    private static func media(_ entities: [String: HAEntity]) -> [String]? {
        let players = byDomain(entities, "media_player").filter {
            ($0.state == "playing" || $0.state == "paused") && !$0.entityId.contains("spotify")
        }
        if players.isEmpty { return nil }

        return players.map { e in
            let title = e.mediaTitle ?? "Unknown"
            let label = e.mediaArtist.map { "\"\(title)\" — \($0)" } ?? "\"\(title)\""
            return "\(name(e)): \(label) [\(e.state)]"
        }
    }

    private static func lights(_ entities: [String: HAEntity]) -> [String] {
        let all = byDomain(entities, "light")
        let on = all.filter { $0.state == "on" }
        if all.isEmpty { return ["No lights found."] }
        let names = on.map { name($0) }.joined(separator: ", ")
        let suffix = on.isEmpty ? "." : " (\(names))."
        return ["Lights: \(on.count)/\(all.count) on\(suffix)"]
    }

    private static func appliances(_ entities: [String: HAEntity]) -> [String] {
        var lines: [String] = []

        for appliance in ["dishwasher", "washing_machine"] {
            let status = entities["sensor.\(appliance)"] ?? entities["sensor.\(appliance)_status"]
            guard let status else { continue }

            let label = appliance == "dishwasher" ? "Dishwasher" : "Washing machine"
            let state = status.state.lowercased()

            if state == "running" || state == "in_use" {
                let program = entities["sensor.\(appliance)_programme"]?.state ?? entities["sensor.\(appliance)_program"]?.state ?? ""
                let remaining = entities["sensor.\(appliance)_remaining_time"]?.state
                var parts = [label]
                if !program.isEmpty { parts.append("(\(program))") }
                if let r = remaining, r != "0" { parts.append("— \(r) min remaining") }
                lines.append(parts.joined(separator: " ") + ".")
            } else if state == "finished" {
                lines.append("\(label): done.")
            } else {
                lines.append("\(label): off.")
            }
        }

        return lines.isEmpty ? ["No appliance data."] : lines
    }

    private static func anomalies(_ entities: [String: HAEntity]) -> [String] {
        var issues: [String] = []
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= 22 || hour < 6

        // TRV target vs actual > 3°C mismatch
        for e in byDomain(entities, "climate") {
            guard let current = e.currentTemperature, let target = e.targetTemperature else { continue }
            if target <= 7 { continue }
            let diff = abs(current - target)
            if diff > 3 {
                issues.append("\(name(e)) target \(String(format: "%.1f", target))°C but reading \(String(format: "%.1f", current))°C (\(String(format: "%.1f", diff))°C mismatch).")
            }
        }

        // Doors open at night
        if isNight {
            let openDoors = byDomain(entities, "binary_sensor").filter {
                let dc = $0.attributes["device_class"]?.stringValue
                return (dc == "door" || dc == "opening") && !applianceDoorIds.contains($0.entityId) && $0.state == "on"
            }
            for d in openDoors {
                issues.append("\(name(d)) open at night.")
            }
        }

        // Extreme temperatures
        for e in byDomain(entities, "climate") {
            guard let temp = e.currentTemperature else { continue }
            if temp < 5 { issues.append("\(name(e)) below 5°C (\(String(format: "%.1f", temp))°C).") }
            if temp > 30 { issues.append("\(name(e)) above 30°C (\(String(format: "%.1f", temp))°C).") }
        }

        // Appliance problems
        for e in byDomain(entities, "binary_sensor") {
            if e.entityId.hasSuffix("_problem") && e.state == "on" {
                issues.append("\(name(e)): problem detected.")
            }
        }

        // Heating but already > 2°C above target
        for e in byDomain(entities, "climate") {
            guard e.hvacAction == "heating",
                  let current = e.currentTemperature,
                  let target = e.targetTemperature else { continue }
            if current > target + 2 {
                issues.append("\(name(e)) heating but already \(String(format: "%.1f", current))°C (target \(String(format: "%.1f", target))°C).")
            }
        }

        return issues.isEmpty ? ["None detected."] : issues
    }
}
