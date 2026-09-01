import Foundation
import SwiftUI

/// A single activity trail entry representing a motion detection event at a position on the floor plan.
struct ActivityTrailEntry: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let floor: Int
    let timestamp: Date

    /// Age of the trail entry in seconds.
    var age: TimeInterval {
        Date().timeIntervalSince(timestamp)
    }

    /// Opacity that decays linearly from 1.0 to 0.0 over 20 seconds.
    var opacity: Double {
        let maxAge: TimeInterval = 20
        let remaining = maxAge - age
        return max(0, min(1, remaining / maxAge))
    }

    /// Whether this trail entry has expired (older than 20 seconds).
    var isExpired: Bool {
        age >= 20
    }
}

/// Monitors motion sensor entities for off-to-on transitions and maintains
/// a time-decaying trail of activity positions on the floor plan.
@Observable
@MainActor
final class ActivityTrailService {
    /// Current trail entries (automatically cleaned up while a trail is visible).
    private(set) var trails: [ActivityTrailEntry] = []

    /// Tracks the previous state of each motion entity to detect off->on transitions.
    private var previousMotionStates: [String: Bool] = [:]

    private var cleanupTask: Task<Void, Never>?
    private var isMonitoring = false

    /// Start monitoring motion entities. Call this once when the floor plan appears.
    func startMonitoring() {
        isMonitoring = true
    }

    /// Stop monitoring and clear all trails.
    func stopMonitoring() {
        isMonitoring = false
        cleanupTask?.cancel()
        cleanupTask = nil
        trails.removeAll()
        previousMotionStates.removeAll()
    }

    /// Update trail state based on current entities and device positions.
    /// Call this whenever entities change (e.g., from the HAClient polling).
    func update(entities: [String: HAEntity], devices: [FloorPlanDevice]) {
        guard isMonitoring else { return }
        var addedTrail = false
        for device in devices where device.type == "motion" {
            let entityId = device.entityId
            guard let entity = entities[entityId] else { continue }

            let isOn = entity.isOn
            let wasOn = previousMotionStates[entityId] ?? false

            // Detect off -> on transition
            if isOn && !wasOn {
                let entry = ActivityTrailEntry(
                    x: device.x,
                    y: device.y,
                    floor: device.floor,
                    timestamp: Date()
                )
                trails.append(entry)
                addedTrail = true
            }

            previousMotionStates[entityId] = isOn
        }

        // Also check camera motion sensors (they have positions from FloorPlanData.cameras)
        for camera in FloorPlanData.cameras {
            let entityId = camera.motionEntityId
            guard let entity = entities[entityId] else { continue }

            let isOn = entity.isOn
            let wasOn = previousMotionStates[entityId] ?? false

            if isOn && !wasOn {
                let entry = ActivityTrailEntry(
                    x: camera.cx,
                    y: camera.cy,
                    floor: 0, // cameras are ground floor only
                    timestamp: Date()
                )
                trails.append(entry)
                addedTrail = true
            }

            previousMotionStates[entityId] = isOn
        }

        // Clean up expired trails on each update too
        removeExpiredTrails()
        if addedTrail { startCleanupIfNeeded() }
    }

    /// A periodic wake-up is useful only while there is something fading on
    /// screen. The task ends as soon as the final trail expires.
    private func startCleanupIfNeeded() {
        guard cleanupTask == nil, !trails.isEmpty else { return }
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.removeExpiredTrails()
                if self.trails.isEmpty {
                    self.cleanupTask = nil
                    return
                }
            }
        }
    }

    /// Remove trails older than 20 seconds.
    private func removeExpiredTrails() {
        trails.removeAll { $0.isExpired }
    }

    /// Get trail entries for a specific floor.
    func trails(for floor: Int) -> [ActivityTrailEntry] {
        trails.filter { $0.floor == floor }
    }
}
