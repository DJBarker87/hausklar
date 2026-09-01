import AppIntents

/// Natural-language Siri phrases for the hands-full voice layer. Each phrase must
/// include the app name; the system registers these when the app is installed.
///
/// Note: Apple only permits `AppEntity`/`AppEnum` parameters to be interpolated
/// into a phrase — free-text `String` parameters cannot appear inline. So the
/// phrases invoke each intent and Siri then asks for the value using the
/// parameter's `requestValueDialog` (e.g. "What should I add to the shopping list?").
struct HausKlarAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddShoppingItemIntent(),
            phrases: [
                "Add to my \(.applicationName) shopping list",
                "Add a shopping item to \(.applicationName)",
                "New \(.applicationName) shopping item",
            ],
            shortTitle: "Add to shopping list",
            systemImageName: "cart.badge.plus"
        )

        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Create a \(.applicationName) task",
                "New \(.applicationName) task",
            ],
            shortTitle: "Add a task",
            systemImageName: "checklist"
        )

        AppShortcut(
            intent: AskBismarckIntent(),
            phrases: [
                "Ask \(.applicationName) Bismarck",
                "Ask my \(.applicationName) assistant",
                "Ask Bismarck in \(.applicationName)",
            ],
            shortTitle: "Ask Bismarck",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: OpenNextEventIntent(),
            phrases: [
                "Open my next event in \(.applicationName)",
                "What's next in \(.applicationName)",
            ],
            shortTitle: "Open next event",
            systemImageName: "calendar.badge.clock"
        )

        AppShortcut(
            intent: OpenActiveNapIntent(),
            phrases: [
                "Open the active nap in \(.applicationName)",
                "Check the nap in \(.applicationName)",
            ],
            shortTitle: "Open active nap",
            systemImageName: "moon.zzz.fill"
        )

        AppShortcut(
            intent: OpenDogCareIntent(),
            phrases: [
                "Open dog care in \(.applicationName)",
                "Check the dog in \(.applicationName)",
            ],
            shortTitle: "Open dog care",
            systemImageName: "pawprint.fill"
        )

        AppShortcut(
            intent: CaptureTextIntent(),
            phrases: [
                "Capture something in \(.applicationName)",
                "Write this down in \(.applicationName)",
            ],
            shortTitle: "Capture text",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: OpenStarChartIntent(),
            phrases: [
                "Open the star chart in \(.applicationName)",
                "Check stars in \(.applicationName)",
            ],
            shortTitle: "Open star chart",
            systemImageName: "star.fill"
        )

        AppShortcut(
            intent: ReviewMedicineIntent(),
            phrases: [
                "Review medicine timing in \(.applicationName)",
                "Check medicine in \(.applicationName)",
            ],
            shortTitle: "Review medicine",
            systemImageName: "cross.case.fill"
        )
    }
}
