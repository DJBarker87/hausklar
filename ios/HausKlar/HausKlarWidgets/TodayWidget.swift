import SwiftUI
import WidgetKit

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HausKlarToday", provider: GlanceProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Next event, remaining events, tasks due and tonight's dinner.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                inlineView
            case .accessoryRectangular:
                rectangularView
            case .systemMedium:
                mediumView
            default:
                smallView
            }
        }
        .privacySensitive()
        .widgetURL(primaryURL)
    }

    // MARK: - Small

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("TODAY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)

            if entry.glance == nil {
                openAppView
            } else {
                if let next = entry.nextEvent {
                    Text(next.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(entry.timeLabel(for: next))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No more events")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 2)

                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                    Text(summaryCountLabel)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let dinner = entry.currentDinner {
                    HStack(spacing: 4) {
                        Image(systemName: "fork.knife")
                        Text(dinner.title)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium

    private var mediumView: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("TODAY")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)

                if entry.glance == nil {
                    openAppView
                } else {
                    if let next = entry.nextEvent {
                        Text(next.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(entry.timeLabel(for: next))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No more events")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                        Text(summaryCountLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let dinner = entry.currentDinner {
                        HStack(spacing: 4) {
                            Image(systemName: "fork.knife")
                            Text(dinner.title)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if entry.glance != nil {
                VStack(alignment: .leading, spacing: 7) {
                    if entry.upcomingEvents.isEmpty {
                        Text("Nothing else on")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(entry.upcomingEvents.prefix(3)) { event in
                            Link(destination: AmbientDeepLink.calendarEvent(id: event.id)) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(entry.timeLabel(for: event))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        .frame(width: 42, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(event.title)
                                            .font(.caption)
                                            .lineLimit(1)
                                        if let person = event.personName {
                                            Text(person)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                memoryThumbnail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "On this day" photo on the trailing edge; skipped when no memory is available.
    @ViewBuilder
    private var memoryThumbnail: some View {
        if let cgImage = entry.memoryImage {
            if let assetId = entry.glance?.memory?.assetId {
                Link(destination: AmbientDeepLink.photo(assetId: assetId)) {
                    VStack(spacing: 4) {
                        Image(uiImage: UIImage(cgImage: cgImage))
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        if let caption = entry.memoryCaption {
                            Text(caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Lock screen

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 1) {
            if entry.glance == nil {
                Text("HausKlar")
                    .font(.headline)
                Text("Open in HausKlar")
                    .font(.caption)
            } else if let next = entry.nextEvent {
                Text(next.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.timeLabel(for: next))
                    .font(.caption)
                Text(summaryCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No more events")
                    .font(.headline)
                Text(summaryCountLabel)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inlineView: some View {
        Group {
            if entry.glance == nil {
                Text("Open in HausKlar")
            } else if let next = entry.nextEvent {
                Text("\(next.title) \(entry.timeLabel(for: next))")
            } else if entry.tasksDueCount > 0 {
                Text(
                    entry.tasksDueCount == 1
                        ? "1 task due".widgetLocalized
                        : WidgetCopy.format(
                            "%lld tasks due",
                            Int64(entry.tasksDueCount)
                        )
                )
            } else {
                Text("All clear today")
            }
        }
    }

    // MARK: - Shared pieces

    private var summaryCountLabel: String {
        let events = entry.remainingEventCount
        let tasks = entry.tasksDueCount
        let eventPart = events == 1
            ? "1 event".widgetLocalized
            : WidgetCopy.format("%lld events", Int64(events))
        let taskPart = tasks == 1
            ? "1 task due".widgetLocalized
            : WidgetCopy.format("%lld tasks due", Int64(tasks))
        return "\(eventPart) · \(taskPart)"
    }

    private var openAppView: some View {
        Text("Open in HausKlar")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var primaryURL: URL {
        entry.nextEvent.map { AmbientDeepLink.calendarEvent(id: $0.id) }
            ?? AmbientDeepLink.today
    }

}

// MARK: - Family Jobs

struct FamilyJobsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HausKlarFamilyJobs", provider: GlanceProvider()) { entry in
            FamilyJobsWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Family jobs")
        .description("Active nap, dog care, capture and the current star chart.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct AmbientJob: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let url: URL
}

private struct FamilyJobsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry

    var body: some View {
        Group {
            if entry.glance == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FAMILY")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("Open in HausKlar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if family == .systemMedium {
                mediumView
            } else {
                compactView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .privacySensitive()
        .widgetURL(primaryJob.url)
    }

    private var compactView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(primaryJob.title, systemImage: primaryJob.symbol)
                .font(.headline)
                .foregroundStyle(primaryJob.tint)
                .lineLimit(2)
            Text(primaryJob.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("Open in HausKlar")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FAMILY JOBS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
            HStack(spacing: 8) {
                VStack(spacing: 8) {
                    jobCard(napJob)
                    jobCard(captureJob)
                }
                VStack(spacing: 8) {
                    jobCard(dogJob)
                    jobCard(starJob)
                }
            }
        }
    }

    private func jobCard(_ job: AmbientJob) -> some View {
        Link(destination: job.url) {
            HStack(spacing: 8) {
                Image(systemName: job.symbol)
                    .foregroundStyle(job.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(job.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(job.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var napJob: AmbientJob {
        guard let nap = entry.activeNap else {
            return AmbientJob(
                id: "nap", title: "Naps".widgetLocalized,
                detail: "None active".widgetLocalized, symbol: "moon.zzz",
                tint: .purple, url: AmbientDeepLink.naps
            )
        }
        let start = ISODateParser.parse(nap.startedAt)
            .map(ISODateParser.timeOnly(from:)) ?? ""
        return AmbientJob(
            id: "nap",
            title: WidgetCopy.format("%@ is asleep", nap.childName),
            detail: WidgetCopy.format("Since %@", start),
            symbol: "moon.zzz.fill", tint: .purple,
            url: AmbientDeepLink.activeNap(napId: nap.id, childId: nap.childId)
        )
    }

    private var dogJob: AmbientJob {
        guard let care = entry.currentDogCare else {
            return AmbientJob(
                id: "dog", title: "Dog care".widgetLocalized,
                detail: "Open care".widgetLocalized, symbol: "pawprint.fill",
                tint: .teal, url: AmbientDeepLink.dogCare()
            )
        }
        let job = care.nextJob
        let title: String
        switch job.action {
        case "feed_breakfast":
            title = WidgetCopy.format("Breakfast for %@", care.dogName)
        case "feed_dinner":
            title = WidgetCopy.format("Dinner for %@", care.dogName)
        case "walk", "active_walk":
            title = WidgetCopy.format("%@'s walk", care.dogName)
        default:
            title = WidgetCopy.format("%@'s care", care.dogName)
        }
        return AmbientJob(
            id: "dog", title: title, detail: job.detail.widgetLocalized,
            symbol: "pawprint.fill",
            tint: .teal,
            url: AmbientDeepLink.dogCare(action: job.action, activityId: job.activityId)
        )
    }

    private var captureJob: AmbientJob {
        AmbientJob(
            id: "capture", title: "Capture".widgetLocalized,
            detail: "Write it down".widgetLocalized, symbol: "square.and.pencil",
            tint: .blue, url: AmbientDeepLink.capture()
        )
    }

    private var starJob: AmbientJob {
        guard let chart = entry.glance?.starChart else {
            return AmbientJob(
                id: "star", title: "Star charts".widgetLocalized,
                detail: "Open charts".widgetLocalized, symbol: "star.fill",
                tint: .yellow, url: AmbientDeepLink.starCharts
            )
        }
        let starCount = chart.starsCount == 1
            ? "1 star".widgetLocalized
            : WidgetCopy.format("%lld stars", Int64(chart.starsCount))
        return AmbientJob(
            id: "star", title: chart.childName,
            detail: WidgetCopy.format(
                "%@ of %lld",
                starCount,
                Int64(chart.totalCells)
            ),
            symbol: "star.fill", tint: .yellow,
            url: AmbientDeepLink.starChart(childId: chart.childId, chartId: chart.chartId)
        )
    }

    private var primaryJob: AmbientJob {
        if entry.activeNap != nil { return napJob }
        if let care = entry.currentDogCare,
           care.activeWalkId != nil
            || [care.breakfastState, care.walkState, care.dinnerState]
                .contains(where: { $0 == "due" || $0 == "overdue" }) {
            return dogJob
        }
        if entry.glance?.starChart != nil { return starJob }
        return captureJob
    }
}
