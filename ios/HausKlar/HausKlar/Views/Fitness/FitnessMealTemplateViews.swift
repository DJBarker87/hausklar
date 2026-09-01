import SwiftUI

struct FitnessMealTemplateLibraryView: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let openSheet: (FitnessNutritionSheet) -> Void
    @State private var archive: FitnessMealTemplate?

    var body: some View {
        List {
            Section {
                Button("New meal template", systemImage: "plus") { openSheet(.newTemplate(nil)) }
            }
            if viewModel.templates.isEmpty {
                ContentUnavailableView(
                    "No meal templates", systemImage: "fork.knife",
                    description: Text("Save a meal from the diary or build a reusable template here.")
                )
            }
            ForEach(viewModel.templates.filter(\.active)) { template in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(template.name).font(.headline)
                            Text("\(template.meal.title) · \(template.items.count) items")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if template.favourite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    }
                    ForEach(template.items) { item in
                        Text("• \(item.label ?? "Saved item") · \(item.amount.formatted()) \(item.unit)")
                            .font(.caption)
                    }
                    HStack {
                        Button("Log") { openSheet(.logTemplate(template.id)) }.buttonStyle(.borderedProminent)
                        Button("Amend") { openSheet(.editTemplate(template.id)) }.buttonStyle(.bordered)
                        Button("Archive", role: .destructive) { archive = template }.buttonStyle(.bordered)
                    }
                }.padding(.vertical, 4)
            }
        }
        .refreshable { await viewModel.refresh() }
        .confirmationDialog(
            "Archive meal template?",
            isPresented: Binding(
                get: { archive != nil }, set: { if !$0 { archive = nil } }
            )
        ) {
            Button("Archive", role: .destructive) {
                if let archive {
                    Task {
                        _ = await viewModel.archiveTemplate(archive)
                        self.archive = nil
                    }
                }
            }
        }
    }
}

struct FitnessMealTemplateEditorSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    var editing: FitnessMealTemplate? = nil
    var seedMeal: FitnessMeal? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var meal = FitnessMeal.breakfast
    @State private var favourite = false
    @State private var items: [FitnessMealTemplateItem] = []
    @State private var source = ""
    @State private var amount = ""
    @State private var quality = FitnessNutritionMeasurementQuality.standardServing
    @State private var didSeed = false

    private var selectedFood: FitnessFood? {
        source.hasPrefix("food:") ? viewModel.foods.first { $0.id == String(source.dropFirst(5)) } : nil
    }
    private var selectedRecipe: FitnessRecipe? {
        source.hasPrefix("recipe:") ? viewModel.recipes.first { $0.id == String(source.dropFirst(7)) } : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    TextField("Name", text: $name)
                    Picker("Meal", selection: $meal) { ForEach(FitnessMeal.allCases) { Text($0.title).tag($0) } }
                    Toggle("Favourite", isOn: $favourite)
                }
                Section("Add item") {
                    Picker("Food or recipe", selection: $source) {
                        Text("Choose…").tag("")
                        Section("Foods") {
                            ForEach(viewModel.foods.filter { $0.currentVersion != nil }) { Text($0.name).tag("food:\($0.id)") }
                        }
                        Section("Recipes") {
                            ForEach(viewModel.recipes.filter { $0.currentVersion != nil }) { Text($0.name).tag("recipe:\($0.id)") }
                        }
                    }.onChange(of: source) { _, _ in seedSourceAmount() }
                    HStack {
                        TextField("Usual amount", text: $amount).keyboardType(.decimalPad)
                        Text(sourceUnit).foregroundStyle(.secondary)
                    }
                    Picker("Quality", selection: $quality) {
                        ForEach(FitnessNutritionMeasurementQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Add item", systemImage: "plus") { addItem() }
                        .disabled(source.isEmpty || FitnessNutritionViewFormatting.number(amount) == nil)
                }
                Section("Separate diary entries") {
                    ForEach(items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.label ?? "Saved item")
                                Text("\(item.amount.formatted()) \(item.unit)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                items.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Text("Logging this template creates separate entries. You can amend every amount before saving.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editing == nil ? "Meal template" : "Amend template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(name.isEmpty || items.isEmpty)
                }
            }
            .onAppear { seedIfNeeded() }
        }
    }

    private var sourceUnit: String {
        selectedFood?.currentVersion?.referenceUnit ?? (selectedRecipe?.currentVersion?.finishedWeightG == nil ? "serving" : "g")
    }
    private func seedSourceAmount() {
        if let version = selectedFood?.currentVersion {
            amount = String(version.referenceAmount)
        } else if let version = selectedRecipe?.currentVersion {
            amount = version.finishedWeightG == nil ? "1" : "100"
        }
    }
    private func addItem() {
        guard let value = FitnessNutritionViewFormatting.number(amount), value > 0 else { return }
        let foodVersion = selectedFood?.currentVersion
        let recipeVersion = selectedRecipe?.currentVersion
        guard (foodVersion == nil) != (recipeVersion == nil) else { return }
        items.append(
            FitnessMealTemplateItem(
                id: UUID().uuidString, foodVersionId: foodVersion?.id, recipeVersionId: recipeVersion?.id,
                label: selectedFood?.name ?? selectedRecipe?.name, amount: value, unit: sourceUnit,
                canonicalAmount: value, canonicalUnit: sourceUnit, measurementQuality: quality, sequence: items.count
            ))
        source = ""
        amount = ""
    }
    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        if let editing {
            name = editing.name
            meal = editing.meal
            favourite = editing.favourite
            items = editing.items
        } else if let seedMeal {
            meal = seedMeal
            name = "\(seedMeal.title) template"
            items = viewModel.day.entries.filter { $0.meal == seedMeal }.enumerated().map { index, entry in
                FitnessMealTemplateItem(
                    id: UUID().uuidString, foodVersionId: entry.foodVersionId,
                    recipeVersionId: entry.recipeVersionId, label: entry.foodName,
                    amount: entry.enteredAmount, unit: entry.enteredUnit,
                    canonicalAmount: entry.canonicalAmount, canonicalUnit: entry.canonicalUnit,
                    measurementQuality: entry.measurementQuality, sequence: index
                )
            }
        }
    }
    private func save() async {
        let value = FitnessMealTemplate(
            id: editing?.id ?? UUID().uuidString, name: name, meal: meal, timeRelevance: meal.rawValue,
            favourite: favourite, active: editing?.active ?? true,
            items: items.enumerated().map { index, item in
                var copy = item
                copy.sequence = index
                return copy
            },
            revision: editing?.revision ?? 0, updatedAt: Date(), deletedAt: nil
        )
        if await viewModel.saveTemplate(value, baseRevision: editing?.revision) { dismiss() }
    }
}

struct FitnessLogTemplateSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let template: FitnessMealTemplate
    @Environment(\.dismiss) private var dismiss
    @State private var loggedAt = Date()
    @State private var amounts: [String: String] = [:]
    @State private var isLogging = false
    // One id per template item, minted with the sheet, so logging the template
    // twice by accident cannot put every item in the diary a second time.
    @State private var entryIds: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("When", selection: $loggedAt)
                Section("Amend before logging") {
                    ForEach(template.items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.label ?? "Saved item")
                                Text("Usual amount: \(item.amount.formatted()) \(item.unit)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField(
                                "Amount",
                                text: Binding(
                                    get: { amounts[item.id] ?? String(item.amount) },
                                    set: { amounts[item.id] = $0 }
                                )
                            ).keyboardType(.decimalPad).frame(width: 80)
                            Text(item.unit).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Each item becomes its own diary entry so later analysis remains useful.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle(template.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log \(template.items.count) entries") {
                        Task { await logTemplate() }
                    }
                    .disabled(isLogging)
                }
            }
            .onAppear {
                guard entryIds.isEmpty else { return }
                entryIds = Dictionary(
                    uniqueKeysWithValues: template.items.map { ($0.id, UUID().uuidString) }
                )
            }
        }
    }

    private func logTemplate() async {
        guard !isLogging else { return }
        isLogging = true
        defer { isLogging = false }
        let values = Dictionary(
            uniqueKeysWithValues: template.items.map { item in
                (item.id, Double(amounts[item.id] ?? "") ?? item.amount)
            })
        let logged = await viewModel.logTemplate(
            template, amounts: values, at: loggedAt, entryIds: entryIds
        )
        if logged { dismiss() }
    }
}
