import SwiftUI

struct FitnessMoreView: View {
    let openActivities: () -> Void
    let openCoach: () -> Void
    let openRecovery: () -> Void
    let openMeasurements: () -> Void
    let openInsights: () -> Void
    let openConnections: () -> Void

    var body: some View {
        List {
            Section {
                destination(
                    "Activities", detail: "Every completed run, ride and workout",
                    symbol: "clock.arrow.circlepath", action: openActivities
                )
                destination(
                    "Coach", detail: "Review your evidence and decide what comes next",
                    symbol: "bubble.left.and.text.bubble.right.fill", action: openCoach
                )
                destination(
                    "Recovery", detail: "Sleep, readiness and body issues",
                    symbol: "heart.text.clipboard", action: openRecovery
                )
                destination(
                    "Body measurements", detail: "Weight, body composition and trends",
                    symbol: "scalemass", action: openMeasurements
                )
                destination(
                    "Insights", detail: "Explore a focused question across your records",
                    symbol: "chart.line.uptrend.xyaxis", action: openInsights
                )
                destination(
                    "Connections", detail: "Strava, Intervals.icu, Garmin and Withings",
                    symbol: "link", action: openConnections
                )
            } header: {
                Text("History, coaching and connections")
            }
        }
        .navigationTitle("More")
    }

    private func destination(
        _ title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticManager.selection()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 54)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}
