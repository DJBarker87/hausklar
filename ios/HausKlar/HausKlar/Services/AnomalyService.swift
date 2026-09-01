import Foundation
import SwiftUI

/// Service for detecting home anomalies and sending local push notifications.
/// Extracted from HomeViewModel to keep anomaly detection logic self-contained.
@MainActor
final class AnomalyService: ObservableObject {

    /// Tracks which anomalies have already been notified to avoid duplicate alerts.
    private var previousAnomalies: Set<String> = []

    /// Check for anomalies and send local push notifications when the app is backgrounded.
    /// Only fires for *new* anomalies not already in `previousAnomalies`.
    func checkForAnomalies(
        scenePhase: ScenePhase,
        doorStatuses: [HomeViewModel.DoorStatus],
        entities: [String: HAEntity],
        heatingRooms: [HomeViewModel.HeatingRoom]
    ) {
        // Only fire notifications when app is in background
        guard scenePhase != .active else {
            // Still track current anomalies so we don't fire stale alerts on background transition
            updateCurrentAnomalySet(doorStatuses: doorStatuses, entities: entities, heatingRooms: heatingRooms)
            return
        }

        var currentAnomalies: Set<String> = []
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= 22 || hour < 7

        // Check doors open at night
        for door in doorStatuses {
            if door.isOpen && isNight {
                let key = "door_\(door.id)"
                currentAnomalies.insert(key)
                if !previousAnomalies.contains(key) {
                    NotificationService.shared.sendSecurityAlert(
                        title: "Door Open at Night",
                        body: "\(door.name) is open"
                    )
                }
            }
        }

        // Check devices offline
        for (entityId, entity) in entities {
            if entity.state == "unavailable" {
                let key = "offline_\(entityId)"
                currentAnomalies.insert(key)
                if !previousAnomalies.contains(key) {
                    let name = entity.friendlyName
                    NotificationService.shared.sendAnomalyAlert(
                        title: "Device Offline",
                        body: "\(name) is unavailable"
                    )
                }
            }
        }

        // Check TRV temperature mismatch (>3 degrees off target)
        for room in heatingRooms {
            guard let current = room.currentTemp, let target = room.targetTemp else { continue }
            if target > 7 && abs(current - target) > 3 {
                let key = "temp_mismatch_\(room.id)"
                currentAnomalies.insert(key)
                if !previousAnomalies.contains(key) {
                    NotificationService.shared.sendAnomalyAlert(
                        title: "Temperature Mismatch",
                        body: "\(room.name) is \(String(format: "%.1f", current))\u{00B0}C but target is \(String(format: "%.1f", target))\u{00B0}C"
                    )
                }
            }
        }

        previousAnomalies = currentAnomalies
    }

    /// Update the anomaly tracking set without sending notifications (used when app is active).
    private func updateCurrentAnomalySet(
        doorStatuses: [HomeViewModel.DoorStatus],
        entities: [String: HAEntity],
        heatingRooms: [HomeViewModel.HeatingRoom]
    ) {
        var currentAnomalies: Set<String> = []
        let hour = Calendar.current.component(.hour, from: Date())
        let isNight = hour >= 22 || hour < 7

        for door in doorStatuses {
            if door.isOpen && isNight {
                currentAnomalies.insert("door_\(door.id)")
            }
        }
        for (entityId, entity) in entities {
            if entity.state == "unavailable" {
                currentAnomalies.insert("offline_\(entityId)")
            }
        }
        for room in heatingRooms {
            guard let current = room.currentTemp, let target = room.targetTemp else { continue }
            if target > 7 && abs(current - target) > 3 {
                currentAnomalies.insert("temp_mismatch_\(room.id)")
            }
        }
        previousAnomalies = currentAnomalies
    }
}
