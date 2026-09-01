import SwiftUI
import WidgetKit

struct MedicineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HausKlarMedicine", provider: GlanceProvider()) { entry in
            MedicineWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Medicine")
        .description("Shows the parent-entered reminder interval for recorded medicine doses.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct MedicineWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry

    var body: some View {
        Group {
            if entry.medicineStatusNeedsReview {
                reviewView
            } else if let medicine = entry.activeMedicine {
                if family == .accessoryRectangular {
                    rectangularView(medicine)
                } else {
                    smallView(medicine)
                }
            } else {
                emptyView
            }
        }
        .privacySensitive()
        .widgetURL(
            entry.activeMedicine.map {
                AmbientDeepLink.medicineReview(
                    childId: $0.childId,
                    medicineTypeId: $0.medicineTypeId
                )
            } ?? AmbientDeepLink.medicineReview(childId: nil, medicineTypeId: nil)
        )
    }

    private var reviewView: some View {
        Group {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Medicine")
                        .font(.headline)
                    Text("Status could not refresh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Open to review")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Medicine", systemImage: "cross.case.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text("Status could not refresh")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("Open to review")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func smallView(_ medicine: GlanceMedicineDTO) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "cross.case.fill")
                Text(medicine.childName.uppercased())
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.red)

            Text(medicine.medicineName)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 2)

            if entry.isReady(medicine) {
                Text("Interval passed")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.blue)
            } else if let safeAt = medicine.nextSafeAt.flatMap(ISODateParser.parse) {
                countdownText(to: safeAt)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                Text(WidgetCopy.format(
                    "Ends %@",
                    ISODateParser.timeOnly(from: safeAt)
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Open to review")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if let last = medicine.lastGivenAt.flatMap(ISODateParser.parse) {
                Text(WidgetCopy.format(
                    "Last %@",
                    ISODateParser.timeOnly(from: last)
                ))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rectangularView(_ medicine: GlanceMedicineDTO) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(medicine.childName) · \(medicine.medicineName)")
                .font(.headline)
                .lineLimit(1)
            if entry.isReady(medicine) {
                Text("Interval passed")
                    .font(.title3.weight(.bold))
            } else if let safeAt = medicine.nextSafeAt.flatMap(ISODateParser.parse) {
                countdownText(to: safeAt)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                Text(WidgetCopy.format(
                    "Ends %@",
                    ISODateParser.timeOnly(from: safeAt)
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Open to review")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyView: some View {
        Group {
            if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Medicine")
                        .font(.headline)
                    Text("No medicines being tracked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    Text("No medicines being tracked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func countdownText(to end: Date) -> Text {
        Text(timerInterval: min(entry.date, end)...end, countsDown: true, showsHours: true)
    }
}
