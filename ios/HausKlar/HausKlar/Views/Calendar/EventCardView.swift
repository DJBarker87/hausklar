import SwiftUI

/// Displays a single calendar event with time, title, location, and a colour indicator.
struct EventCardView: View {
    @EnvironmentObject private var appState: AppState
    let event: CalendarEventDTO
    let displayDate: Date
    let viewModel: CalendarViewModel
    let onSelect: () -> Void

    private var occurrenceTimeLabel: String {
        viewModel.occurrenceTimeLabel(for: event, on: displayDate)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Colour indicator based on assignment
                RoundedRectangle(cornerRadius: 3)
                    .fill(event.sourceColor.map(Color.init(hex:)) ?? viewModel.colorForEvent(event))
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    // Time range
                    Text(occurrenceTimeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontWeight(.medium)

                    // Title
                    HStack(spacing: 6) {
                        Text(event.title)
                            .font(.body)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .strikethrough(event.isCancelledSchoolClub)
                        if event.recurrenceRule != nil {
                            Image(systemName: "repeat")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if event.sourceDocumentId != nil || event.sourceDocument != nil {
                            Image(systemName: "paperclip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Has attachment")
                        }
                    }

                    if event.isFitnessProjection {
                        Label(
                            event.eventType == "fitness_completed" ? "Workout" : "Training",
                            systemImage: event.eventType == "fitness_completed"
                                ? "figure.run" : "dumbbell.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else if event.isSchoolClubProjection {
                        Label(
                            event.isCancelledSchoolClub ? "Club · cancelled" : "Term-time club",
                            systemImage: event.isCancelledSchoolClub
                                ? "calendar.badge.exclamationmark" : "figure.run.circle"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else if event.isToastProjection {
                        Label("Toast pickup window", systemImage: "clock.arrow.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let category = event.financeCategoryLabel {
                        Label(
                            category,
                            systemImage: event.eventType == "finance_delivery"
                                ? "truck.box" : "wallet.bifold"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    } else if let sourceName = event.sourceName {
                        Label(sourceName, systemImage: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(viewModel.participantLabel(for: event))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(viewModel.colorForEvent(event).opacity(0.15))
                        .foregroundStyle(viewModel.colorForEvent(event))
                        .cornerRadius(4)

                    if let affected = viewModel.affectedLabel(for: event) {
                        Text("Affects \(affected)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Location
                    if let location = event.location, !location.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.caption2)
                            Text(location)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }

                    // Description
                    if !event.isFinanceManaged,
                        let description = event.description,
                        !description.isEmpty
                    {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.horizontal, event.isSchoolMilestone ? 10 : 0)
            .padding(.vertical, event.isSchoolMilestone ? 12 : 4)
            .frame(maxWidth: .infinity, minHeight: event.isSchoolMilestone ? 82 : 44, alignment: .leading)
            .background {
                if event.isSchoolMilestone {
                    SchoolMilestoneBackground()
                } else if appState.highlightedCalendarResultId == event.id {
                    Color.accentColor.opacity(0.14)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .overlay {
                if appState.highlightedCalendarResultId == event.id {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            {
                var label = event.title
                if !occurrenceTimeLabel.isEmpty {
                    label += ", \(occurrenceTimeLabel)"
                }
                label += ", going: \(viewModel.participantLabel(for: event))"
                if let affected = viewModel.affectedLabel(for: event) {
                    label += ", also affects \(affected)"
                }
                if let location = event.location, !location.isEmpty {
                    label += ", at \(location)"
                }
                return label
            }()
        )
        .accessibilityHint(
            appState.highlightedCalendarResultId == event.id
                ? "Newly created by Bismarck. Opens event details"
                : "Opens event details"
        )
    }
}

/// A static, low-noise sprinkle treatment for rare family milestones.
struct SchoolMilestoneBackground: View {
    private let sprinkles: [(CGFloat, CGFloat, Color, Double)] = [
        (0.68, 0.18, .pink, 18),
        (0.79, 0.34, .orange, -24),
        (0.9, 0.17, .cyan, 42),
        (0.72, 0.64, .purple, -38),
        (0.86, 0.72, .green, 12),
        (0.95, 0.5, .yellow, 58),
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color.yellow.opacity(0.17), Color.pink.opacity(0.11)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                ForEach(Array(sprinkles.enumerated()), id: \.offset) { _, sprinkle in
                    Capsule()
                        .fill(sprinkle.2)
                        .frame(width: 9, height: 3)
                        .rotationEffect(.degrees(sprinkle.3))
                        .position(
                            x: proxy.size.width * sprinkle.0,
                            y: proxy.size.height * sprinkle.1
                        )
                        .opacity(0.72)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.pink.opacity(0.22), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}
