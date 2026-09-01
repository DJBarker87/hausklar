import AVKit
import Foundation

/// View model for camera management, extracted from HomeViewModel.
/// Handles door camera video retrieval, event selection, and snapshot management.
@MainActor
final class CameraViewModel: ObservableObject {

    // MARK: - Published State

    @Published var errorMessage: String?

    let haClient: HAClient

    init(haClient: HAClient) {
        self.haClient = haClient
    }

    // MARK: - Door Camera Mapping

    /// Maps door entity IDs to their associated Ring camera event select entities.
    static let doorCameraMap: [String: String] = [
        "binary_sensor.example_e1938001": "select.front_door_event_select",
        "binary_sensor.example_cadfe0f1": "select.patio_event_select",
    ]

    // MARK: - Camera Event Filtering

    /// Get filtered event options for a camera event select entity (excluding transcoded/on-demand).
    func filteredCameraEvents(for eventSelectId: String) -> [String] {
        let options = haClient.entities[eventSelectId]?.selectOptions ?? []
        return options.filter { option in
            let lower = option.lowercased()
            return !lower.contains("transcoded") && !lower.contains("on-demand")
        }
    }

    /// Select an option on a select entity (e.g. camera event select).
    func selectEventOption(_ entityId: String, option: String) async {
        haClient.updateEntityOptimistically(entityId, state: option)
        do {
            try await haClient.callService(domain: "select", service: "select_option", data: [
                "entity_id": entityId,
                "option": option,
            ])
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
        haClient.scheduleBackgroundRefresh(delay: 3.0)
    }

    // MARK: - Door Camera History Matching

    /// Find the event option closest to a door's lastOpenedAt timestamp using HA history API.
    /// Returns the matched index within filteredCameraEvents, or nil if no match within window.
    func findClosestEventViaHistory(for doorId: String, lastOpenedAt: Date?) async -> (options: [String], index: Int)? {
        guard let eventSelectId = Self.doorCameraMap[doorId],
              let lastOpened = lastOpenedAt else { return nil }

        let options = filteredCameraEvents(for: eventSelectId)
        guard !options.isEmpty else { return nil }

        // Fetch real timestamps from HA history API
        let history = await haClient.fetchEventSelectHistory(entityId: eventSelectId)
        guard !history.isEmpty else { return nil }

        // Build a set of option names currently available for quick lookup
        let optionSet = Set(options)

        // Find the history entry closest to lastOpened within -600s to +120s window
        var bestOptionName: String?
        var bestDistance: TimeInterval = .greatestFiniteMagnitude

        for entry in history {
            guard optionSet.contains(entry.state) else { continue }
            let diff = entry.timestamp.timeIntervalSince(lastOpened)
            guard diff >= -600 && diff <= 120 else { continue }
            let distance = abs(diff)
            if distance < bestDistance {
                bestDistance = distance
                bestOptionName = entry.state
            }
        }

        guard let matchedName = bestOptionName,
              let index = options.firstIndex(of: matchedName) else { return nil }
        return (options, index)
    }

    /// Select a camera event and poll for the recording URL, returning an AVPlayer.
    func fetchDoorVideo(eventSelectId: String, option: String) async -> AVPlayer? {
        // Select the event option
        await selectEventOption(eventSelectId, option: option)

        // Poll for recordingUrl
        var recordingPath: String?
        for attempt in 0..<5 {
            if attempt > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return nil
                }
                do {
                    _ = try await haClient.fetchSingleEntityState(eventSelectId)
                } catch is CancellationError {
                    return nil
                } catch {
                    // Continue the bounded poll because the entity cache may
                    // still receive the recording URL from another HA refresh.
                    errorMessage = "Camera status could not be refreshed."
                }
            }
            if let entity = haClient.entities[eventSelectId],
               let url = entity.recordingUrl, !url.isEmpty {
                recordingPath = url
                break
            }
        }

        guard recordingPath != nil else { return nil }

        // HA recording URLs may be private, token-bearing, or redirect to an
        // origin outside HausKlar. Do not let model/entity data choose a network
        // destination for iOS. Recorded playback remains unavailable until a
        // bounded authenticated backend endpoint owns this transport.
        errorMessage = "Recorded video is unavailable in secure mode."
        return nil
    }

    /// Check if door cameras are available based on current door statuses and events.
    func doorCameraAvailability(doorStatuses: [HomeViewModel.DoorStatus]) -> [String: Bool] {
        var available: [String: Bool] = [:]
        for door in doorStatuses {
            if let eventSelectId = Self.doorCameraMap[door.id] {
                let events = filteredCameraEvents(for: eventSelectId)
                available[door.id] = !events.isEmpty && door.lastOpenedAt != nil
            } else {
                available[door.id] = false
            }
        }
        return available
    }
}
