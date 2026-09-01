import SwiftUI

struct FacilityTimetableImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: CalendarViewModel

    let onImported: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                if viewModel.facilityImportBusy,
                    viewModel.facilityImportPreview == nil
                {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Reading timetable")
                                    .font(.headline)
                                Text("Checking every pool and weights-room entry…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                if let error = viewModel.facilityImportError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } footer: {
                        Text("Nothing has been changed. Close this review and choose the file again.")
                    }
                }

                if let preview = viewModel.facilityImportPreview {
                    Section("Timetable") {
                        LabeledContent("File", value: preview.filename)
                        LabeledContent(
                            "Dates",
                            value: "\(preview.validFrom) – \(preview.validTo)"
                        )
                        LabeledContent("Days", value: String(preview.counts.days))
                    }

                    Section("Availability found") {
                        LabeledContent(
                            "Family swimming",
                            value: "\(preview.counts.familySwimmingSessions) sessions"
                        )
                        LabeledContent(
                            "Lane swimming",
                            value: "\(preview.counts.laneSwimmingSessions) sessions"
                        )
                        LabeledContent(
                            "Weights room",
                            value: "\(preview.counts.weightsRoomOpenDays) open days"
                        )
                        if preview.counts.poolClosedDays > 0 {
                            LabeledContent(
                                "Pool closures",
                                value: String(preview.counts.poolClosedDays)
                            )
                        }
                        Text("Family swimming is shared. Lane swimming and weights are shown only to Alex.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if preview.changes.addedDays > 0
                        || preview.changes.changedDays > 0
                        || preview.changes.removedDays > 0
                    {
                        Section("Changes from the current timetable") {
                            LabeledContent("New days", value: String(preview.changes.addedDays))
                            LabeledContent("Changed days", value: String(preview.changes.changedDays))
                            LabeledContent("Removed days", value: String(preview.changes.removedDays))
                        }
                    }

                    if !preview.sampleDays.isEmpty {
                        Section("Sample days") {
                            ForEach(preview.sampleDays, id: \.date) { day in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(day.date)
                                        .font(.subheadline.weight(.semibold))
                                    Text(day.familySwimmingLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let weights = day.weightsRoomLabel {
                                        Text(weights)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }

                    if !preview.issues.isEmpty {
                        Section("Check before importing") {
                            ForEach(preview.issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle")
                            }
                        }
                    }

                    if preview.alreadyImported {
                        Section {
                            Label(
                                "This timetable is already current.",
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                        }
                    } else {
                        Section {
                            Label(
                                "Nothing changes until you confirm. The original Word file will be filed with the imported schedule.",
                                systemImage: "checkmark.shield"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Review Example School timetable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.facilityImportPreview?.alreadyImported == true ? "Done" : "Cancel") {
                        viewModel.discardFacilityImport()
                        dismiss()
                    }
                    .disabled(viewModel.facilityImportBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.facilityImportPreview?.canConfirm == true {
                        Button {
                            Task {
                                if await viewModel.confirmSchoolTimetable() {
                                    HapticManager.success()
                                    onImported(
                                        viewModel.facilityImportNotice
                                            ?? "Example School timetable updated."
                                    )
                                    dismiss()
                                }
                            }
                        } label: {
                            if viewModel.facilityImportBusy {
                                ProgressView()
                            } else {
                                Text("Use timetable")
                                    .fontWeight(.semibold)
                            }
                        }
                        .disabled(viewModel.facilityImportBusy)
                    }
                }
            }
        }
        .interactiveDismissDisabled(viewModel.facilityImportBusy)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
