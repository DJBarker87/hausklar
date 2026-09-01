import Foundation
import UserNotifications
import UIKit
import os

extension Notification.Name {
    static let hausklarReminderOpened = Notification.Name("hausklarReminderOpened")
}

final class HausKlarNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await NotificationService.shared.registerRemoteDeviceToken(token) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationService.shared.remoteRegistrationFailed(error)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let url = response.notification.request.content.userInfo["url"] as? String else { return }
        NotificationCenter.default.post(name: .hausklarReminderOpened, object: url)
    }
}

/// Manages local push notifications for security alerts and anomaly detection.
/// Notifications are delivered when the app is in the background.
final class NotificationService: @unchecked Sendable {
    static let shared = NotificationService()

    private static let logger = Logger(subsystem: "org.example.hausklar", category: "NotificationService")
    private let privacyStore: NotificationPrivacyPolicyStore
    private let remoteStateLock = NSLock()
    private var remoteDeliveryIdentity: String?
    private var remoteTokenDigest: String?

    init(privacyStore: NotificationPrivacyPolicyStore = .shared) {
        self.privacyStore = privacyStore
    }

    /// Request notification permission from the user.
    func requestPermission() async -> Bool {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            if allowed {
                await registerForRemoteNotificationsIfAllowed()
            }
            return allowed
        } catch {
            Self.logger.error("Permission error: \(error.localizedDescription)")
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func registerForRemoteNotificationsIfAllowed() async {
        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional || status == .ephemeral,
              APIClient.shared.cacheIdentity != nil else { return }
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func registerRemoteDeviceToken(_ token: String) async {
        guard let ownerIdentity = APIClient.shared.cacheIdentity else { return }
#if DEBUG
        let environment = "sandbox"
#else
        let environment = "production"
#endif
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        do {
            let status: APNSDeviceStatusDTO = try await APIClient.shared.post(
                "/reminders/apns/devices",
                body: APNSDeviceRegistrationRequest(
                    deviceToken: token,
                    environment: environment,
                    appVersion: appVersion
                )
            )
            guard APIClient.shared.cacheIdentity == ownerIdentity else { return }
            remoteStateLock.withLock {
                remoteDeliveryIdentity = status.configured && status.registered
                    ? ownerIdentity
                    : nil
                remoteTokenDigest = status.tokenDigest
            }
            if status.configured && status.registered {
                await removeServerReminderFallbacks()
            }
        } catch {
            Self.logger.error(
                "Could not register this device for remote notifications: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func remoteRegistrationFailed(_ error: Error) {
        Self.logger.error(
            "Apple notification registration failed: \(error.localizedDescription, privacy: .private)"
        )
    }

    func unregisterRemoteNotificationsFromServer() async {
        let state = remoteStateLock.withLock {
            (remoteTokenDigest, remoteDeliveryIdentity)
        }
        if let digest = state.0,
           state.1 == APIClient.shared.cacheIdentity {
            do {
                try await APIClient.shared.delete("/reminders/apns/devices/\(digest)")
            } catch {
                Self.logger.warning(
                    "Could not remove this device's remote notification registration: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        stopRemoteNotifications()
    }

    func stopRemoteNotifications() {
        remoteStateLock.withLock {
            remoteDeliveryIdentity = nil
            remoteTokenDigest = nil
        }
        Task { @MainActor in
            UIApplication.shared.unregisterForRemoteNotifications()
        }
    }

    private func remoteDeliveryIsActive(for identity: String) -> Bool {
        remoteStateLock.withLock { remoteDeliveryIdentity == identity }
    }

    private func removeServerReminderFallbacks() async {
        let center = UNUserNotificationCenter.current()
        let managed = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("REMINDER-") }
        center.removePendingNotificationRequests(withIdentifiers: managed)
    }

    func scheduleReminders(preferences: ReminderPreferencesDTO, items: [ReminderPreviewDTO]) async {
        let ownerIdentity = APIClient.shared.cacheIdentity
        privacyStore.update(privacyMode: preferences.privacyMode, for: ownerIdentity)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let managed = pending.map(\.identifier).filter { $0.hasPrefix("REMINDER-") }
        center.removePendingNotificationRequests(withIdentifiers: managed)
        guard await authorizationStatus() == .authorized,
              ownerIdentity != nil,
              APIClient.shared.cacheIdentity == ownerIdentity else { return }
        if let ownerIdentity, remoteDeliveryIsActive(for: ownerIdentity) {
            return
        }

        let parser = ISO8601DateFormatter()
        for item in items.prefix(40) {
            guard HausKlarReminderRoute(value: item.url) != nil,
                  let date = parser.date(from: item.scheduledFor), date > Date() else { continue }
            let value = String(format: "%02d:%02d", Calendar.current.component(.hour, from: date), Calendar.current.component(.minute, from: date))
            let quiet = preferences.quietStart > preferences.quietEnd
                ? value >= preferences.quietStart || value < preferences.quietEnd
                : value >= preferences.quietStart && value < preferences.quietEnd
            if preferences.quietStart != preferences.quietEnd && quiet { continue }
            let content = UNMutableNotificationContent()
            let display = NotificationPrivacyPolicy.displayContent(
                kind: .reminderPreview(item.kind),
                title: item.title,
                body: item.detail,
                privacyMode: preferences.privacyMode
            )
            content.title = display.title
            content.body = display.body
            content.sound = .default
            content.categoryIdentifier = "REMINDER"
            content.userInfo = ["url": item.url]
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
            await add(
                UNNotificationRequest(
                    identifier: "REMINDER-\(item.id)",
                    content: content,
                    trigger: trigger
                ),
                to: center,
                ownerIdentity: ownerIdentity
            )
        }

        if preferences.morningSummaryEnabled {
            let parts = preferences.morningSummaryTime.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 {
                let content = UNMutableNotificationContent()
                let display = NotificationPrivacyPolicy.displayContent(
                    kind: .summary,
                    title: "Today in HausKlar",
                    body: "Your family plan is ready.",
                    privacyMode: preferences.privacyMode
                )
                content.title = display.title
                content.body = display.body
                content.sound = .default
                content.categoryIdentifier = "REMINDER"
                content.userInfo = ["url": "/?view=today"]
                let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: parts[0], minute: parts[1]), repeats: true)
                await add(
                    UNNotificationRequest(
                        identifier: "REMINDER-MORNING",
                        content: content,
                        trigger: trigger
                    ),
                    to: center,
                    ownerIdentity: ownerIdentity
                )
            }
        }

        if preferences.eveningSummaryEnabled {
            let parts = preferences.eveningSummaryTime.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 {
                let content = UNMutableNotificationContent()
                let display = NotificationPrivacyPolicy.displayContent(
                    kind: .summary,
                    title: "Tomorrow, sorted",
                    body: "Take one calm look at tomorrow’s family plan.",
                    privacyMode: preferences.privacyMode
                )
                content.title = display.title
                content.body = display.body
                content.sound = .default
                content.categoryIdentifier = "REMINDER"
                content.userInfo = ["url": "/?view=today&tomorrow=1"]
                let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: parts[0], minute: parts[1]), repeats: true)
                await add(
                    UNNotificationRequest(
                        identifier: "REMINDER-EVENING",
                        content: content,
                        trigger: trigger
                    ),
                    to: center,
                    ownerIdentity: ownerIdentity
                )
            }
        }
    }

    func refreshHausKlarReminders() async {
        guard await authorizationStatus() == .authorized else { return }
        await registerForRemoteNotificationsIfAllowed()
        do {
            async let preferences: ReminderPreferencesDTO = APIClient.shared.get("/reminders/preferences")
            async let preview: [ReminderPreviewDTO] = APIClient.shared.get("/reminders/preview")
            await scheduleReminders(preferences: try await preferences, items: try await preview)
        } catch {
            Self.logger.error("Could not refresh reminders: \(error.localizedDescription)")
        }
    }

    /// Every local notification can contain family-derived titles or timing. Remove
    /// pending and already-delivered content whenever the local identity is hidden.
    func clearIdentityBoundNotifications() {
        privacyStore.clear()
        remoteStateLock.withLock {
            remoteDeliveryIdentity = nil
            remoteTokenDigest = nil
        }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    func sendTestReminder() async {
        let ownerIdentity = APIClient.shared.cacheIdentity
        if let ownerIdentity, remoteDeliveryIsActive(for: ownerIdentity) {
            do {
                let _: NotificationTestResultDTO = try await APIClient.shared.post(
                    "/reminders/apns/test"
                )
                return
            } catch {
                Self.logger.error(
                    "Remote test reminder failed; using the on-device fallback: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
        let privacyMode = privacyStore.privacyMode(for: ownerIdentity)
        let content = UNMutableNotificationContent()
        let display = NotificationPrivacyPolicy.displayContent(
            kind: .test,
            title: "HausKlar reminders are ready",
            body: "You’ll get useful nudges based on your settings.",
            privacyMode: privacyMode
        )
        content.title = display.title
        content.body = display.body
        content.sound = .default
        content.categoryIdentifier = "REMINDER"
        content.userInfo = ["url": "/?view=today"]
        await add(
            UNNotificationRequest(
                identifier: "REMINDER-TEST",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            ),
            to: .current(),
            ownerIdentity: ownerIdentity
        )
    }

    func scheduleForgottenNap(
        napId: String,
        childId: String,
        childName: String,
        startedAt: Date,
        afterMinutes: Int
    ) async {
        let ownerIdentity = APIClient.shared.cacheIdentity
        cancelNapReminder(napId: napId)
        guard ownerIdentity != nil,
              afterMinutes > 0,
              await authorizationStatus() == .authorized else { return }
        let fireAt = startedAt.addingTimeInterval(Double(afterMinutes) * 60)
        guard fireAt > Date() else { return }

        let content = UNMutableNotificationContent()
        let display = NotificationPrivacyPolicy.displayContent(
            kind: .nap,
            title: "Is \(childName) still asleep?",
            body: "Open the active nap if it needs ending or correcting.",
            privacyMode: privacyStore.privacyMode(for: ownerIdentity)
        )
        content.title = display.title
        content.body = display.body
        content.sound = .default
        content.categoryIdentifier = "REMINDER"
        content.userInfo = [
            "url": "/?view=family&section=naps&child=\(childId)&nap=\(napId)"
        ]
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: fireAt.timeIntervalSinceNow,
            repeats: false
        )
        await add(
            UNNotificationRequest(identifier: "NAP-\(napId)", content: content, trigger: trigger),
            to: .current(),
            ownerIdentity: ownerIdentity
        )
    }

    func cancelNapReminder(napId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["NAP-\(napId)"]
        )
    }

    func cancelAllNapReminders() async {
        let center = UNUserNotificationCenter.current()
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("NAP-") }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// Send a critical security alert (e.g. door open at night).
    func sendSecurityAlert(title: String, body: String) {
        guard let ownerIdentity = APIClient.shared.cacheIdentity else { return }
        let display = NotificationPrivacyPolicy.displayContent(
            kind: .security,
            title: title,
            body: body,
            privacyMode: privacyStore.privacyMode(for: ownerIdentity)
        )
        let content = UNMutableNotificationContent()
        content.title = display.title
        content.body = display.body
        content.sound = .default
        content.categoryIdentifier = "SECURITY"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Send a non-critical anomaly alert (e.g. device offline, temperature mismatch).
    func sendAnomalyAlert(title: String, body: String) {
        guard let ownerIdentity = APIClient.shared.cacheIdentity else { return }
        let display = NotificationPrivacyPolicy.displayContent(
            kind: .anomaly,
            title: title,
            body: body,
            privacyMode: privacyStore.privacyMode(for: ownerIdentity)
        )
        let content = UNMutableNotificationContent()
        content.title = display.title
        content.body = display.body
        content.sound = .default
        content.categoryIdentifier = "ANOMALY"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Register notification categories with action buttons.
    func setupCategories() {
        let dismissAction = UNNotificationAction(identifier: "DISMISS", title: "Dismiss", options: .destructive)
        let viewAction = UNNotificationAction(identifier: "VIEW", title: "View Details", options: .foreground)

        let securityCategory = UNNotificationCategory(
            identifier: "SECURITY",
            actions: [viewAction, dismissAction],
            intentIdentifiers: []
        )

        let anomalyCategory = UNNotificationCategory(
            identifier: "ANOMALY",
            actions: [viewAction, dismissAction],
            intentIdentifiers: []
        )

        let reminderCategory = UNNotificationCategory(
            identifier: "REMINDER",
            actions: [viewAction, dismissAction],
            intentIdentifiers: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([securityCategory, anomalyCategory, reminderCategory])
    }

    private func add(
        _ request: UNNotificationRequest,
        to center: UNUserNotificationCenter,
        ownerIdentity: String?
    ) async {
        guard let ownerIdentity,
              APIClient.shared.cacheIdentity == ownerIdentity else { return }
        do {
            try await center.add(request)
        } catch {
            Self.logger.error("Could not schedule local notification: \(error.localizedDescription, privacy: .private)")
        }
    }
}
