import SwiftUI

struct FitnessGoalTemplateSheet: View {
    @ObservedObject var viewModel: FitnessTrainingViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId = ""
    @State private var targetValue = 0.0
    @State private var customTitle = ""
    @State private var hasDate = false
    @State private var targetDate = Date()

    private var selected: FitnessGoalTemplate? {
        viewModel.goalTemplates.first { $0.id == selectedId }
    }
    private let primaryIds: Set<String> = [
        "run-faster-5k", "run-weekly-distance", "run-consistently",
        "strength-consistency", "move-consistently",
    ]
    private var primaryTemplates: [FitnessGoalTemplate] {
        viewModel.goalTemplates.filter { primaryIds.contains($0.id) }
    }
    private var otherTemplates: [FitnessGoalTemplate] {
        viewModel.goalTemplates.filter { !primaryIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What matters most?") {
                    ForEach(primaryTemplates) { template in templateButton(template) }
                    if !otherTemplates.isEmpty {
                        DisclosureGroup("Other goals") {
                            ForEach(otherTemplates) { template in templateButton(template) }
                        }
                    }
                }
                if let selected {
                    Section(selected.targetPrompt) {
                        if selected.inputKind == .durationMinutesSeconds {
                            HStack(alignment: .lastTextBaseline, spacing: 8) {
                                TextField("Minutes", value: targetMinutes, format: .number)
                                    .keyboardType(.numberPad)
                                Text(":").font(.headline.monospacedDigit())
                                TextField("Seconds", value: targetSeconds, format: .number)
                                    .keyboardType(.numberPad)
                            }
                            .textFieldStyle(.roundedBorder)
                            Text("Run 5K in \(duration(targetValue))")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Stepper(value: $targetValue, in: selected.minimumValue...selected.maximumValue, step: selected.step) {
                                Text("\(display(targetValue,whole:selected.inputKind.usesWholeNumbers)) \(selected.unitLabel)")
                            }
                        }
                        DisclosureGroup("Optional details") {
                            TextField("Goal name", text: $customTitle)
                            if selected.supportsTargetDate {
                                Toggle("Add a target date", isOn: $hasDate)
                                if hasDate {
                                    DatePicker("Target date", selection: $targetDate, in: Date()..., displayedComponents: .date)
                                }
                            }
                        }
                    }
                }
                if let error = viewModel.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Choose a goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let selected else { return }
                        Task {
                            if await viewModel.createGoal(
                                from: selected, targetValue: targetValue,
                                targetDate: hasDate ? targetDate : nil, title: customTitle
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(selected == nil || viewModel.isLoading)
                }
            }
            .task {
                if viewModel.goalTemplates.isEmpty { await viewModel.loadManage() }
                if selectedId.isEmpty, let first = primaryTemplates.first ?? viewModel.goalTemplates.first {
                    selectedId = first.id
                    targetValue = first.suggestedValue
                }
            }
        }
    }

    private func display(_ value: Double, whole: Bool) -> String {
        whole ? String(Int(value.rounded())) : value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func templateButton(_ template: FitnessGoalTemplate) -> some View {
        Button {
            selectedId = template.id
            targetValue = template.suggestedValue
            HapticManager.selection()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedId == template.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedId == template.id ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.title).foregroundStyle(.primary)
                    Text(template.description).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
        }
    }

    private var targetMinutes: Binding<Int> {
        Binding(
            get: { max(0, Int(targetValue.rounded()) / 60) },
            set: { targetValue = Double(max(0, $0) * 60 + Int(targetValue.rounded()) % 60) }
        )
    }

    private var targetSeconds: Binding<Int> {
        Binding(
            get: { max(0, Int(targetValue.rounded()) % 60) },
            set: { targetValue = Double((Int(targetValue.rounded()) / 60) * 60 + min(59, max(0, $0))) }
        )
    }

    private func duration(_ value: Double) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct FitnessBodyIssueFields: View {
    @Binding var issue: NewBodyIssue
    let locations: [FitnessBodyLocation]
    private let issueTypes = ["pain", "tightness", "discomfort", "weakness", "injury", "other"]
    private let sides = ["left", "right", "bilateral", "midline", "not_applicable", "unknown"]
    private let changes = ["reduced_load", "reduced_range", "reduced_pace", "substituted", "stopped", "prevented_start", "other"]
    var body: some View {
        Picker("Type", selection: $issue.issueTypeKey) { ForEach(issueTypes, id: \.self) { Text($0.capitalized).tag($0) } }
        Picker("Body location", selection: $issue.bodyLocationKey) {
            Text("Choose…").tag("")
            ForEach(locations.filter(\.active)) { location in
                Text(location.displayName).tag(location.locationKey)
            }
            if !issue.bodyLocationKey.isEmpty && !locations.contains(where: { $0.locationKey == issue.bodyLocationKey }) {
                Text(FitnessBodyLocation.label(for: issue.bodyLocationKey, locations: locations)).tag(issue.bodyLocationKey)
            }
        }
        Picker("Side", selection: $issue.side) {
            ForEach(sides, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
        }
        Stepper("Severity \(issue.severity)/10", value: $issue.severity, in: 0...10)
        Toggle("Changed the session", isOn: $issue.changedSession)
            .onChange(of: issue.changedSession) { _, changed in issue.sessionChangeKey = changed ? "reduced_load" : "none" }
        if issue.changedSession {
            Picker("Change", selection: $issue.sessionChangeKey) {
                ForEach(changes, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
            }
        }
        TextField(
            "Notes (optional)",
            text: Binding(
                get: { issue.note ?? "" },
                set: { issue.note = $0.isEmpty ? nil : $0 }
            ),
            axis: .vertical
        )
    }
}
