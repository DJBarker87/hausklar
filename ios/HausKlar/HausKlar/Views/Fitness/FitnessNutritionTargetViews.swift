import SwiftUI

struct FitnessNutritionTargetsView: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let add: () -> Void
    @State private var boundary = 240
    @State private var heartRateZones = [120, 140, 155, 170]
    @State private var archive: FitnessNutritionTarget?

    var body: some View {
        List {
            if let error = viewModel.errorMessage { Section { Text(error).foregroundStyle(.red) } }
            Section("Nutrition day boundary") {
                Stepper(value: $boundary, in: 0...480, step: 15) {
                    LabeledContent("Day starts", value: String(format: "%02d:%02d", boundary / 60, boundary % 60))
                }
                Button("Save boundary and rebucket diary") {
                    Task { _ = await viewModel.rebucket(minutes: boundary) }
                }.disabled(boundary == viewModel.settings.nutritionDayStartMinutes)
                Text(
                    "Reconnect to change this because HausKlar must regroup every existing diary entry using the timezone in which it was recorded."
                )
                .font(.footnote).foregroundStyle(.secondary)
                if let status = viewModel.statusMessage { Text(status).foregroundStyle(.green) }
            }
            Section {
                DisclosureGroup("Advanced activity settings") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Heart-rate zone boundaries")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "Optional. These four boundaries split imported activity heart-rate data into five zones. Use values you already follow; HausKlar does not prescribe them."
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                        ForEach(heartRateZones.indices, id: \.self) { index in
                            Stepper(value: $heartRateZones[index], in: 60...240) {
                                LabeledContent("Zone \(index + 1) upper boundary", value: "\(heartRateZones[index]) bpm")
                            }
                        }
                        Button("Save heart-rate zones") {
                            Task { _ = await viewModel.saveHeartRateZones(heartRateZones) }
                        }
                        .disabled(!zonesAreValid || heartRateZones == viewModel.settings.heartRateZoneBoundariesBpm)
                        if !zonesAreValid {
                            Text("Boundaries must be unique and increase from Zone 1 to Zone 4.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Section {
                Button("Add nutrition target", systemImage: "plus") { add() }
                if viewModel.targets.filter(\.active).isEmpty {
                    Text("The diary works without targets. Wearable exercise Calories are never added automatically.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.targets.filter(\.active)) { target in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(target.metric.title).font(.headline)
                            Text(FitnessNutritionViewFormatting.targetDescription(target)).foregroundStyle(.secondary)
                            Text("\(target.effectiveFrom)\(target.effectiveUntil.map { " – \($0)" } ?? " onwards")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            archive = target
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Targets")
            }
        }
        .onAppear {
            boundary = viewModel.settings.nutritionDayStartMinutes
            heartRateZones = viewModel.settings.heartRateZoneBoundariesBpm ?? [120, 140, 155, 170]
        }
        .onChange(of: viewModel.settings) { _, settings in
            boundary = settings.nutritionDayStartMinutes
            heartRateZones = settings.heartRateZoneBoundariesBpm ?? heartRateZones
        }
        .refreshable { await viewModel.refresh() }
        .confirmationDialog(
            "Archive nutrition target?",
            isPresented: Binding(
                get: { archive != nil }, set: { if !$0 { archive = nil } }
            )
        ) {
            Button("Archive", role: .destructive) {
                if let archive {
                    Task {
                        _ = await viewModel.archiveTarget(archive)
                        self.archive = nil
                    }
                }
            }
        }
    }

    private var zonesAreValid: Bool {
        heartRateZones.count == 4
            && heartRateZones == heartRateZones.sorted()
            && Set(heartRateZones).count == 4
    }
}

struct FitnessNutritionTargetEditorSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    @Environment(\.dismiss) private var dismiss
    private let editing: FitnessNutritionTarget?
    private let targetId: String
    @State private var metric = FitnessNutritionMetric.caloriesKcal
    @State private var mode = FitnessNutritionTargetMode.fixed
    @State private var value = ""
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var training = ""
    @State private var rest = ""
    @State private var phaseId = ""
    @State private var effectiveFrom = Date()
    @State private var hasEnd = false
    @State private var effectiveUntil = Date()

    init(
        viewModel: FitnessNutritionViewModel,
        initialMetric: FitnessNutritionMetric = .caloriesKcal,
        editing: FitnessNutritionTarget? = nil
    ) {
        self.viewModel = viewModel
        self.editing = editing
        targetId = editing?.id ?? UUID().uuidString
        let start = editing.flatMap { ISODateParser.parseDateOnly($0.effectiveFrom) } ?? Date()
        let end = editing?.effectiveUntil.flatMap(ISODateParser.parseDateOnly) ?? start
        _metric = State(initialValue: editing?.metric ?? initialMetric)
        _mode = State(initialValue: editing?.mode ?? .fixed)
        _value = State(initialValue: Self.fieldText(editing?.targetValue))
        _minimum = State(initialValue: Self.fieldText(editing?.targetMin))
        _maximum = State(initialValue: Self.fieldText(editing?.targetMax))
        _training = State(initialValue: Self.fieldText(editing?.trainingDayValue))
        _rest = State(initialValue: Self.fieldText(editing?.restDayValue))
        _phaseId = State(initialValue: editing?.phaseId ?? "")
        _effectiveFrom = State(initialValue: start)
        _hasEnd = State(initialValue: editing?.effectiveUntil != nil)
        _effectiveUntil = State(initialValue: max(start, end))
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Picker("Nutrient", selection: $metric) {
                        ForEach(FitnessNutritionMetric.allCases) { Text($0.title).tag($0) }
                    }
                } else {
                    LabeledContent("Nutrient", value: metric.title)
                }
                Picker("Target form", selection: $mode) {
                    ForEach(editableModes) { Text($0.title).tag($0) }
                }
                switch mode {
                case .fixed, .weeklyAverage:
                    targetField("Target", $value)
                case .range:
                    targetField("Minimum", $minimum)
                    targetField("Maximum", $maximum)
                case .trainingRest:
                    targetField("Training day", $training)
                    targetField("Rest day", $rest)
                case .phase:
                    Text("Phase-specific targets can be managed in Advanced nutrition settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                DatePicker("Effective from", selection: $effectiveFrom, displayedComponents: .date)
                Toggle("Effective until", isOn: $hasEnd)
                if hasEnd { DatePicker("Until", selection: $effectiveUntil, in: effectiveFrom..., displayedComponents: .date) }
                Text("Targets use logged intake. Exercise Calories are not automatically added.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("\(metric.title) target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!draft.isValid)
                }
            }
        }
    }

    @ViewBuilder private func targetField(_ title: String, _ text: Binding<String>) -> some View {
        HStack {
            TextField(title, text: text).keyboardType(.decimalPad)
            Text(metric.unit).foregroundStyle(.secondary)
        }
    }

    private var editableModes: [FitnessNutritionTargetMode] {
        let normalModes = FitnessNutritionTargetMode.allCases.filter { $0 != .phase }
        return mode == .phase ? normalModes + [.phase] : normalModes
    }

    private var draft: FitnessNutritionTarget {
        FitnessNutritionTarget(
            id: targetId, metric: metric, mode: mode,
            targetValue: [.fixed, .weeklyAverage, .phase].contains(mode) ? FitnessNutritionViewFormatting.number(value) : nil,
            targetMin: mode == .range ? FitnessNutritionViewFormatting.number(minimum) : nil,
            targetMax: mode == .range ? FitnessNutritionViewFormatting.number(maximum) : nil,
            trainingDayValue: mode == .trainingRest ? FitnessNutritionViewFormatting.number(training) : nil,
            restDayValue: mode == .trainingRest ? FitnessNutritionViewFormatting.number(rest) : nil,
            phaseId: mode == .phase ? FitnessNutritionViewFormatting.emptyNil(phaseId) : nil,
            effectiveFrom: FitnessNutritionViewFormatting.dayString(effectiveFrom),
            effectiveUntil: hasEnd ? FitnessNutritionViewFormatting.dayString(effectiveUntil) : nil,
            active: true, revision: editing?.revision ?? 0, updatedAt: Date(), deletedAt: nil
        )
    }
    private func save() async {
        if await viewModel.saveTarget(draft, baseRevision: editing?.revision) { dismiss() }
    }

    private static func fieldText(_ value: Double?) -> String {
        value.map { String(format: "%g", $0) } ?? ""
    }
}
