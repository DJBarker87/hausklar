import ActivityKit
import Foundation
import os

private let familyLiveActivityLogger=Logger(
    subsystem:"org.example.hausklar",category:"FamilyLiveActivities"
)

/// Manages the medicine next-safe-dose Live Activity.
/// One activity per child + medicine; a new dose for the same child replaces
/// any other activity for that child instead of stacking.
@MainActor
final class MedicineActivityManager {
    static let shared = MedicineActivityManager()

    private init() {}

    func startOrUpdate(
        childId: String?,
        medicineTypeId: String?,
        childName: String,
        medicineName: String,
        nextSafeAt: Date,
        isSafeNow: Bool,
        lastGivenAt: Date?
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = MedicineDoseActivityAttributes.ContentState(
            nextSafeAt: nextSafeAt,
            isSafeNow: isSafeNow,
            lastGivenAt: lastGivenAt
        )
        // staleDate = nextSafeAt so the UI re-renders into the "ready" state on time.
        let content = ActivityContent(state: state, staleDate: isSafeNow ? nil : nextSafeAt)

        Task {
            var updated = false
            for activity in Activity<MedicineDoseActivityAttributes>.activities
            where activity.attributes.childId == childId
                || (activity.attributes.childId == nil && activity.attributes.childName == childName) {
                let hasExactDestination = activity.attributes.childId == childId
                    && activity.attributes.medicineTypeId == medicineTypeId
                if activity.attributes.medicineName == medicineName && hasExactDestination && !updated {
                    await activity.update(content)
                    updated = true
                } else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            guard !updated else { return }
            let attributes = MedicineDoseActivityAttributes(
                childId: childId,
                medicineTypeId: medicineTypeId,
                childName: childName,
                medicineName: medicineName
            )
            do {
                _=try Activity.request(
                    attributes:attributes,content:content,pushType:nil
                )
            } catch {
                familyLiveActivityLogger.error(
                    "Medicine Live Activity could not start: \(error.localizedDescription, privacy:.private)"
                )
            }
        }
    }

    func end(childName: String) {
        Task {
            for activity in Activity<MedicineDoseActivityAttributes>.activities
            where activity.attributes.childName == childName {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func endAll() {
        Task {
            for activity in Activity<MedicineDoseActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Ends activities whose "ready" time passed more than `graceHours` ago.
    /// Called on app foreground so forgotten activities do not linger.
    func endExpired(graceHours: Double = 6) {
        let cutoff = Date().addingTimeInterval(-graceHours * 3600)
        Task {
            for activity in Activity<MedicineDoseActivityAttributes>.activities
            where activity.content.state.nextSafeAt < cutoff {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

@MainActor
final class NapActivityManager {
    static let shared = NapActivityManager()

    private init() {}

    func start(
        napId: String,
        childId: String,
        childName: String,
        startedAt: Date,
        isBedtime: Bool
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = NapActivityAttributes(
            napId: napId,
            childId: childId,
            childName: childName,
            isBedtime: isBedtime
        )
        let content = ActivityContent(
            state: NapActivityAttributes.ContentState(startedAt: startedAt),
            staleDate: nil
        )
        Task {
            for activity in Activity<NapActivityAttributes>.activities
            where activity.attributes.napId == napId {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            do {
                _=try Activity.request(
                    attributes:attributes,content:content,pushType:nil
                )
            } catch {
                familyLiveActivityLogger.error(
                    "Nap Live Activity could not start: \(error.localizedDescription, privacy:.private)"
                )
            }
        }
    }

    func end(napId: String) {
        Task {
            for activity in Activity<NapActivityAttributes>.activities
            where activity.attributes.napId == napId {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func endAll() {
        Task {
            for activity in Activity<NapActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
