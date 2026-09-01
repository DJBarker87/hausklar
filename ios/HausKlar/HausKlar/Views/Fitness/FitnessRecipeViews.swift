import SwiftUI

struct FitnessRecipeLibraryView: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let add: () -> Void
    let log: (String) -> Void
    @State private var selected: FitnessRecipe?

    var body: some View {
        List {
            Section { Button("New recipe", systemImage: "plus", action: add) }
            if viewModel.recipes.isEmpty {
                ContentUnavailableView(
                    "No recipes", systemImage: "frying.pan",
                    description: Text("Combine exact saved food details or record an honest prepared estimate.")
                )
            }
            ForEach(viewModel.recipes) { recipe in
                Button {
                    selected = recipe
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(recipe.name).foregroundStyle(.primary)
                                if recipe.householdShared { Image(systemName: "person.example_f47e224f").font(.caption) }
                                if recipe.favourite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                            }
                            Text("\(recipe.currentVersion?.components.count ?? 0) components")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(recipe.currentVersion?.nutrients.caloriesKcal.map { "\(Int($0.rounded())) kcal" } ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .refreshable { await viewModel.refresh() }
        .sheet(item: $selected) { recipe in
            FitnessRecipeDetailSheet(viewModel: viewModel, recipeId: recipe.id) {
                selected = nil
                log("recipe:\(recipe.id)")
            }
        }
    }
}

private struct FitnessRecipeDetailSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    let recipeId: String
    let log: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showVersion = false
    private var recipe: FitnessRecipe? { viewModel.recipes.first { $0.id == recipeId } }

    var body: some View {
        NavigationStack {
            Form {
                if let recipe {
                    let actions = FitnessNutritionActionAvailability.recipe(recipe)
                    Section("Recipe") {
                        LabeledContent("Name", value: recipe.name)
                        if recipe.editable {
                            Toggle(
                                "Share recipe with household",
                                isOn: Binding(
                                    get: { recipe.householdShared },
                                    set: { value in
                                        var copy = recipe
                                        copy.householdShared = value
                                        Task { _ = await viewModel.saveRecipe(copy) }
                                    }
                                ))
                            Text("The recipe is shared, but each person’s diary remains private.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Label("Household recipe", systemImage: "person.example_f47e224f")
                            Text(
                                "You can log this recipe or copy it. Only its owner can update its details, mark it as a favourite, or archive it."
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                            Button("Copy to my recipes", systemImage: "doc.on.doc") {
                                Task { if await viewModel.copyRecipeToMine(recipe) { dismiss() } }
                            }
                        }
                    }
                    Section("Saved recipe history") {
                        ForEach(recipe.versions.sorted(by: { ($0.versionNumber ?? 0) > ($1.versionNumber ?? 0) })) { version in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recipe details \(version.versionNumber ?? 1)").font(.headline)
                                Text(FitnessNutritionViewFormatting.nutrientLine(version.nutrients)).font(.caption).foregroundStyle(
                                    .secondary)
                                if let lower = version.lowerCaloriesKcal, let upper = version.upperCaloriesKcal {
                                    Text("Prepared estimate: \(lower.formatted())–\(upper.formatted()) kcal")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                ForEach(version.components) { component in
                                    Text(
                                        "• \(component.foodName ?? "Saved food details") · \(component.amount.formatted()) \(component.unit)"
                                    )
                                    .font(.caption)
                                }
                            }
                        }
                        if actions.canAddVersion { Button("Add nutrition details", systemImage: "plus") { showVersion = true } }
                    }
                    Section {
                        if actions.canLog {
                            Button("Log recipe", systemImage: "apple.logo") {
                                dismiss()
                                log()
                            }
                        }
                        if actions.canFavourite {
                            Button(recipe.favourite ? "Remove favourite" : "Add favourite", systemImage: "star") {
                                var copy = recipe
                                copy.favourite.toggle()
                                Task { _ = await viewModel.saveRecipe(copy) }
                            }
                        }
                        if actions.canArchive {
                            Button(recipe.active ? "Archive recipe" : "Restore recipe", systemImage: "archivebox") {
                                var copy = recipe
                                copy.active.toggle()
                                Task { if await viewModel.saveRecipe(copy) { dismiss() } }
                            }
                        }
                    }
                }
            }
            .navigationTitle(recipe?.name ?? "Recipe")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showVersion) {
                if let recipe { FitnessRecipeEditorSheet(viewModel: viewModel, versionFor: recipe) }
            }
        }
    }
}

struct FitnessRecipeEditorSheet: View {
    @ObservedObject var viewModel: FitnessNutritionViewModel
    var versionFor: FitnessRecipe? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""
    @State private var householdShared = false
    @State private var favourite = false
    @State private var prepared = false
    @State private var components: [FitnessRecipeComponent] = []
    @State private var sourceFoodId = ""
    @State private var componentAmount = "100"
    @State private var finishedWeight = ""
    @State private var servings = ""
    @State private var calories = ""
    @State private var lowerCalories = ""
    @State private var upperCalories = ""
    @State private var confidence = "calculated"
    @State private var sourceNote = ""
    @State private var didSeed = false

    private var sourceFood: FitnessFood? { viewModel.foods.first { $0.id == sourceFoodId } }

    var body: some View {
        NavigationStack {
            Form {
                if versionFor == nil {
                    Section("Recipe details") {
                        TextField("Name", text: $name)
                        TextField("Notes", text: $notes, axis: .vertical)
                        Toggle("Share recipe with household", isOn: $householdShared)
                        Toggle("Favourite", isOn: $favourite)
                    }
                }
                Section {
                    Toggle("Prepared / restaurant estimate", isOn: $prepared)
                    Text(
                        prepared
                            ? "Use an honest best estimate and range when ingredients are not known."
                            : "Components keep the exact nutrition details saved with each food."
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if prepared {
                    Section("Prepared estimate") {
                        numberField("Best Calories", $calories)
                        numberField("Lower Calories", $lowerCalories)
                        numberField("Upper Calories", $upperCalories)
                    }
                } else {
                    Section("Components") {
                        Picker("Food", selection: $sourceFoodId) {
                            Text("Choose food").tag("")
                            ForEach(viewModel.foods.filter { $0.currentVersion != nil && $0.active }) { food in
                                Text(food.name).tag(food.id)
                            }
                        }
                        HStack {
                            TextField("Amount", text: $componentAmount).keyboardType(.decimalPad)
                            Text(sourceFood?.currentVersion?.referenceUnit ?? "unit").foregroundStyle(.secondary)
                        }
                        Button("Add component", systemImage: "plus") { addComponent() }
                            .disabled(sourceFood?.currentVersion == nil || Double(componentAmount) == nil)
                        ForEach(components) { component in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(component.foodName ?? "Saved food details")
                                    Text("\(component.amount.formatted()) \(component.unit)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    components.removeAll { $0.id == component.id }
                                } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Yield") {
                    numberField("Finished cooked weight (g, optional)", $finishedWeight)
                    numberField("Servings (optional)", $servings)
                }
                Section("Preparation notes") {
                    TextField("Optional notes", text: $sourceNote, axis: .vertical)
                }
                if let preview = calculatedPreview {
                    Section("Calculated preview") {
                        Text(FitnessNutritionViewFormatting.nutrientLine(preview))
                        if let weight = FitnessNutritionViewFormatting.number(finishedWeight), weight > 0 {
                            Text("Per 100 g: \(preview.scaled(by: 100/weight).caloriesKcal.map { "\($0.formatted()) kcal" } ?? "—")")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(versionFor == nil ? "New recipe" : "Update recipe details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!valid)
                }
            }
            .onAppear { seedIfNeeded() }
        }
    }

    @ViewBuilder private func numberField(_ title: String, _ value: Binding<String>) -> some View {
        TextField(title, text: value).keyboardType(.decimalPad)
    }
    private var valid: Bool {
        (versionFor != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (prepared
                ? FitnessNutritionViewFormatting.number(calories) != nil
                    || (FitnessNutritionViewFormatting.number(lowerCalories) != nil
                        && FitnessNutritionViewFormatting.number(upperCalories) != nil)
                : !components.isEmpty)
    }
    private var calculatedPreview: FitnessNutritionValues? {
        guard !prepared else { return nil }
        let values = components.map { component -> FitnessNutritionValues in
            guard let version = viewModel.foods.flatMap(\.versions).first(where: { $0.id == component.foodVersionId }) else {
                return .unknown
            }
            return version.nutrients.scaled(by: component.canonicalAmount / version.referenceAmount)
        }
        return FitnessNutritionValues.exactTotal(values)
    }
    private func addComponent() {
        guard let food = sourceFood, let version = food.currentVersion, let amount = FitnessNutritionViewFormatting.number(componentAmount),
            amount > 0
        else { return }
        components.append(
            FitnessRecipeComponent(
                id: UUID().uuidString, foodVersionId: version.id, foodName: food.name,
                amount: amount, unit: version.referenceUnit, canonicalAmount: amount,
                canonicalUnit: version.referenceUnit, sequence: components.count
            ))
        sourceFoodId = ""
        componentAmount = "100"
    }
    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        guard let recipe = versionFor, let version = recipe.currentVersion else { return }
        name = recipe.name
        notes = recipe.notes ?? ""
        householdShared = recipe.householdShared
        favourite = recipe.favourite
        prepared = version.components.isEmpty
        components = version.components
        finishedWeight = version.finishedWeightG.map { String($0) } ?? ""
        servings = version.servings.map { String($0) } ?? ""
        calories = version.nutrients.caloriesKcal.map { String($0) } ?? ""
        lowerCalories = version.lowerCaloriesKcal.map { String($0) } ?? ""
        upperCalories = version.upperCaloriesKcal.map { String($0) } ?? ""
        confidence = version.confidence
        sourceNote = version.sourceNote ?? ""
    }
    private func save() async {
        let draft = FitnessRecipeDraft(
            name: versionFor?.name ?? name, notes: versionFor?.notes ?? FitnessNutritionViewFormatting.emptyNil(notes),
            householdShared: versionFor?.householdShared ?? householdShared,
            favourite: versionFor?.favourite ?? favourite,
            components: prepared
                ? []
                : components.enumerated().map { index, value in
                    var copy = value
                    copy.sequence = index
                    return copy
                }, finishedWeightG: FitnessNutritionViewFormatting.number(finishedWeight),
            servings: FitnessNutritionViewFormatting.number(servings),
            caloriesKcal: prepared ? FitnessNutritionViewFormatting.number(calories) : nil,
            lowerCaloriesKcal: prepared ? FitnessNutritionViewFormatting.number(lowerCalories) : nil,
            upperCaloriesKcal: prepared ? FitnessNutritionViewFormatting.number(upperCalories) : nil,
            confidence: confidence, sourceNote: FitnessNutritionViewFormatting.emptyNil(sourceNote)
        )
        let succeeded: Bool
        if let recipe = versionFor {
            succeeded = await viewModel.addRecipeVersion(recipeId: recipe.id, draft: draft)
        } else {
            succeeded = await viewModel.createRecipe(draft)
        }
        if succeeded { dismiss() }
    }
}
