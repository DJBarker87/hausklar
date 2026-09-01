import SwiftUI

/// Full-screen sheet showing all door open/close events for the last 24 hours.
/// Fetches history from the HA History API and parses on/off transitions.
struct DoorHistoryView: View {
    let entityId: String
    let deviceLabel: String

    @State private var events: [DoorEventEntry] = []
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    private static let green = Color.hackerGreen
    private static let red = Color.hackerRed
    private static let grey = Color.hackerGrey
    private static let orange = Color.hackerOrange

    struct DoorEventEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let isOpen: Bool
        /// Duration from this open event to its corresponding close, if available.
        var duration: TimeInterval?
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceLabel.uppercased())
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.green)
                    Text("LAST 24 HOURS")
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

            if loading {
                Spacer()
                ProgressView()
                    .tint(Self.green)
                Text("LOADING HISTORY...")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .padding(.top, 8)
                Spacer()
            } else if events.isEmpty {
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 36))
                    .foregroundStyle(Self.grey)
                Text("NO EVENTS IN LAST 24H")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.grey)
                    .padding(.top, 8)
                Spacer()
            } else {
                // Summary
                let openCount = events.filter(\.isOpen).count
                let closeCount = events.filter { !$0.isOpen }.count
                HStack(spacing: 16) {
                    summaryPill(count: openCount, label: "OPENED", color: Self.red)
                    summaryPill(count: closeCount, label: "CLOSED", color: Self.green)
                }
                .padding(.vertical, 12)
                .padding(.horizontal)

                Divider().background(Self.green.opacity(0.2))

                // Timeline
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            eventRow(event)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .task {
            await fetchHistory()
        }
    }

    private func summaryPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.15))
        )
    }

    private func eventRow(_ event: DoorEventEntry) -> some View {
        HStack(spacing: 12) {
            // Timeline dot + line
            VStack(spacing: 0) {
                Circle()
                    .fill(event.isOpen ? Self.red : Self.green)
                    .frame(width: 10, height: 10)
                Rectangle()
                    .fill(Self.green.opacity(0.15))
                    .frame(width: 1)
            }
            .frame(width: 10)

            // Timestamp
            Text(Self.timestampFormatter.string(from: event.timestamp))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 70, alignment: .leading)

            // State
            Text(event.isOpen ? "OPENED" : "CLOSED")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(event.isOpen ? Self.red : Self.green)

            Spacer()

            // Duration (only shown on open events that have a matching close)
            if event.isOpen, let duration = event.duration {
                Text(Self.formatDuration(duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.orange)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Data Fetching

    private func fetchHistory() async {
        loading = true
        let history = await HAClient.shared.fetchFullDoorHistory(entityId: entityId)
        var parsed: [DoorEventEntry] = []
        for event in history {
            parsed.append(
                DoorEventEntry(
                    timestamp: event.openedAt,
                    isOpen: true,
                    duration: event.duration
                )
            )
            if let closedAt = event.closedAt {
                parsed.append(DoorEventEntry(timestamp: closedAt, isOpen: false))
            }
        }
        events = parsed.sorted { $0.timestamp > $1.timestamp }
        loading = false
    }

    // MARK: - Formatters

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let secs = Int(seconds)
        if secs < 60 { return "\(secs)s" }
        let mins = secs / 60
        let remainder = secs % 60
        if mins < 60 {
            if remainder == 0 { return "\(mins)m" }
            return "\(mins)m \(remainder)s"
        }
        let hours = mins / 60
        let remMins = mins % 60
        return "\(hours)h \(remMins)m"
    }
}
