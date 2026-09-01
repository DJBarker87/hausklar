import Foundation
import os

struct SuggestedAutomation: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let icon: String // SF Symbol name
    let dismissKey: String
    let action: () async -> Void
}

@MainActor
final class ScheduleAutomationService {

    static let shared = ScheduleAutomationService()

    private static let logger = Logger(subsystem: "org.example.hausklar", category: "ScheduleAutomationService")

    private static let dismissedSuggestionsKey = "ScheduleAutomation.dismissedSuggestions"
    private var dismissedSuggestions: [String: Date] // key -> dismissedAt
    private let dismissDuration: TimeInterval = 24 * 3600 // 24h

    private init() {
        // Restore persisted dismissals from UserDefaults
        guard let data = UserDefaults.standard.data(forKey: Self.dismissedSuggestionsKey) else {
            dismissedSuggestions = [:]
            return
        }
        do {
            let decoded = try JSONDecoder().decode([String: Double].self, from: data)
            dismissedSuggestions = decoded.mapValues { Date(timeIntervalSince1970: $0) }
        } catch {
            // A corrupt preference must not crash the suggestion engine, but it
            // remains in defaults until an explicit dismissal/reset replaces it.
            dismissedSuggestions = [:]
            Self.logger.error(
                "Saved automation dismissals could not be decoded: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// Persist dismissed suggestions to UserDefaults.
    private func saveDismissals() {
        let encoded = dismissedSuggestions.mapValues { $0.timeIntervalSince1970 }
        do {
            let data = try JSONEncoder().encode(encoded)
            UserDefaults.standard.set(data, forKey: Self.dismissedSuggestionsKey)
        } catch {
            // Keep the in-memory dismissal for this session and expose the
            // durability failure for diagnostics rather than silently losing it.
            Self.logger.error(
                "Automation dismissals could not be persisted: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// Check upcoming events and generate automation suggestions.
    /// - Parameters:
    ///   - events: Calendar events for today (as DTOs)
    ///   - performAction: Closure to execute HA service calls
    /// - Returns: Array of suggested automations
    func checkAutomations(
        events: [CalendarEventDTO],
        performAction: @escaping (String, String, [String: Any]) async -> Void
    ) -> [SuggestedAutomation] {
        var suggestions: [SuggestedAutomation] = []
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)

        // Clean expired dismissals and persist
        let before = dismissedSuggestions.count
        dismissedSuggestions = dismissedSuggestions.filter { now.timeIntervalSince($0.value) < dismissDuration }
        if dismissedSuggestions.count != before {
            saveDismissals()
        }

        // Rule 1: Morning routine — if school event starts in 30-60min
        let upcoming = events.filter { event in
            guard let start = ISODateParser.parse(event.startTime) else { return false }
            let minutesUntil = start.timeIntervalSince(now) / 60
            return minutesUntil > 0 && minutesUntil <= 60
        }

        for event in upcoming {
            guard let start = ISODateParser.parse(event.startTime) else { continue }
            let minutesUntil = start.timeIntervalSince(now) / 60
            let isSchool = event.title.lowercased().contains("school")

            if isSchool && minutesUntil >= 30 && minutesUntil <= 60 {
                let key = "morning_\(calendar.component(.day, from: now))"
                if dismissedSuggestions[key] == nil {
                    suggestions.append(SuggestedAutomation(
                        title: "Boost Heating",
                        description: "School in \(Int(minutesUntil))min — warm up the house",
                        icon: "flame.fill",
                        dismissKey: key
                    ) {
                        await performAction("scene", "turn_on", ["entity_id": "scene.example_74a1b87c"])
                    })
                }
            }

            // Rule 3: Leaving house — event with location in 30min
            if minutesUntil <= 30, let location = event.location, !location.isEmpty {
                let key = "leaving_\(event.id)"
                if dismissedSuggestions[key] == nil {
                    suggestions.append(SuggestedAutomation(
                        title: "Leaving House",
                        description: "\(event.title) in \(Int(minutesUntil))min",
                        icon: "door.left.hand.open",
                        dismissKey: key
                    ) {
                        await performAction("script", "turn_on", ["entity_id": "script.example_9cd66497"])
                    })
                }
            }
        }

        // Rule 2: Bedtime — if between 20:00 and 22:30
        if hour >= 20 && hour < 23 {
            let key = "bedtime_\(calendar.component(.day, from: now))"
            if dismissedSuggestions[key] == nil {
                suggestions.append(SuggestedAutomation(
                    title: "Goodnight",
                    description: "Run the goodnight routine",
                    icon: "moon.fill",
                    dismissKey: key
                ) {
                    await performAction("script", "turn_on", ["entity_id": "script.example_3ffa9dd3"])
                })
            }
        }

        return suggestions
    }

    /// Reset all dismissed suggestions. Used in tests to ensure clean state.
    func resetDismissals() {
        dismissedSuggestions.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.dismissedSuggestionsKey)
    }

    func dismiss(_ suggestion: SuggestedAutomation) {
        dismissedSuggestions[suggestion.dismissKey] = Date()
        saveDismissals()
        Self.logger.debug("Dismissed suggestion: \(suggestion.title)")
    }
}
