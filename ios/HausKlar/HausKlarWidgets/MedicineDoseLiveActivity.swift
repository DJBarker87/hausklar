import ActivityKit
import SwiftUI
import WidgetKit

struct MedicineDoseLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MedicineDoseActivityAttributes.self) { context in
            LockScreenDoseView(context: context)
                .padding()
                .privacySensitive()
                .widgetURL(medicineReviewURL(context.attributes))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.childName)
                            .font(.headline)
                        Text(context.attributes.medicineName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .privacySensitive()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if isReady(context) {
                        Label("Interval passed", systemImage: "clock.badge.checkmark")
                            .font(.headline)
                            .foregroundStyle(.blue)
                            .privacySensitive()
                    } else {
                        countdownText(context)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .privacySensitive()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(bottomLabel(context))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .privacySensitive()
                }
            } compactLeading: {
                Image(systemName: "cross.case.fill")
                    .foregroundStyle(statusColor(context))
            } compactTrailing: {
                if isReady(context) {
                    Image(systemName: "clock.badge.checkmark")
                        .foregroundStyle(.blue)
                } else {
                    countdownText(context)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 44)
                        .privacySensitive()
                }
            } minimal: {
                Image(systemName: "cross.case.fill")
                    .foregroundStyle(statusColor(context))
            }
            .widgetURL(medicineReviewURL(context.attributes))
            .keylineTint(.orange)
        }
    }
}

private func isReady(_ context: ActivityViewContext<MedicineDoseActivityAttributes>) -> Bool {
    context.state.isSafeNow || context.state.nextSafeAt <= Date()
}

/// Blue means only that the saved interval has passed; it is never medical advice.
private func statusColor(_ context: ActivityViewContext<MedicineDoseActivityAttributes>) -> Color {
    isReady(context) ? .blue : .orange
}

private func countdownText(_ context: ActivityViewContext<MedicineDoseActivityAttributes>) -> Text {
    let end = context.state.nextSafeAt
    return Text(timerInterval: min(Date(), end)...end, countsDown: true, showsHours: true)
}

private func bottomLabel(_ context: ActivityViewContext<MedicineDoseActivityAttributes>) -> String {
    if isReady(context) {
        return "Saved interval has passed — check the label before recording".widgetLocalized
    }
    return WidgetCopy.format(
        "Saved interval ends at %@",
        context.state.nextSafeAt.formatted(date: .omitted, time: .shortened)
    )
}

private struct LockScreenDoseView: View {
    let context: ActivityViewContext<MedicineDoseActivityAttributes>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.childName)
                    .font(.headline)
                Text(context.attributes.medicineName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let last = context.state.lastGivenAt {
                    Text(WidgetCopy.format(
                        "Last dose %@",
                        last.formatted(date: .omitted, time: .shortened)
                    ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if isReady(context) {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    Text("Saved interval passed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    countdownText(context)
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 90, alignment: .trailing)
                    Text("until saved interval ends")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func medicineReviewURL(_ attributes: MedicineDoseActivityAttributes) -> URL {
    AmbientDeepLink.medicineReview(
        childId: attributes.childId,
        medicineTypeId: attributes.medicineTypeId
    )
}

struct NapLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NapActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.attributes.isBedtime ? "moon.zzz.fill" : "bed.double.fill")
                    .font(.title2)
                    .foregroundStyle(context.attributes.isBedtime ? .indigo : .purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.childName)
                        .font(.headline)
                    Text(
                        (context.attributes.isBedtime
                            ? "Bedtime in progress"
                            : "Nap in progress").widgetLocalized
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(context.state.startedAt, style: .timer)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            .padding()
            .privacySensitive()
            .widgetURL(napURL(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(
                        context.attributes.childName,
                        systemImage: context.attributes.isBedtime ? "moon.zzz.fill" : "bed.double.fill"
                    )
                    .font(.headline)
                    .privacySensitive()
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.startedAt, style: .timer)
                        .font(.headline)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(WidgetCopy.format(
                        "Tap to open the active %@",
                        (context.attributes.isBedtime ? "bedtime" : "nap").widgetLocalized
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.attributes.isBedtime ? "moon.zzz.fill" : "bed.double.fill")
                    .foregroundStyle(context.attributes.isBedtime ? .indigo : .purple)
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer)
                    .font(.caption2)
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(.purple)
            }
            .widgetURL(napURL(context))
            .keylineTint(context.attributes.isBedtime ? .indigo : .purple)
        }
    }
}

private func napURL(_ context: ActivityViewContext<NapActivityAttributes>) -> URL {
    AmbientDeepLink.activeNap(
        napId: context.attributes.napId,
        childId: context.attributes.childId
    )
}
